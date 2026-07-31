#include "MediaController.h"

#include <QAudioBuffer>
#include <QAudioDecoder>
#include <QAudioOutput>
#include <QCollator>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QLibraryInfo>
#include <QLocale>
#include <QSettings>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QVersionNumber>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

namespace {
constexpr auto SettingsOrganization = "keyboardspecialist";
constexpr auto VolumeKey = "audio/volume";
constexpr auto MutedKey = "audio/muted";
constexpr auto DirectoryKey = "audio/directory";
constexpr auto CurrentTrackKey = "audio/currentTrack";
constexpr int WaveformBuckets = 128;
constexpr int AnalysisChunkFrames = 256;
constexpr int VisualizerChunkFrames = 1024;
constexpr int VisualizerMaximumSamples = 12000;

QVariantList quietWaveform()
{
    return {};
}

QString cleanError(const QString &message)
{
    QString result = message.simplified();
    if (result.size() > 400)
        result = result.left(397) + QStringLiteral("...");
    return result;
}

QString defaultTracksDirectory()
{
    const QString applicationDirectory = QCoreApplication::applicationDirPath();
    const QStringList candidates = {
        QDir(applicationDirectory).absoluteFilePath(QStringLiteral("tracks")),
        QDir(applicationDirectory).absoluteFilePath(QStringLiteral("../tracks")),
        QDir(applicationDirectory).absoluteFilePath(QStringLiteral("../share/bc250-trainer")),
        QDir::current().absoluteFilePath(QStringLiteral("trainer/tracks")),
        QDir::current().absoluteFilePath(QStringLiteral("tracks"))
    };
    for (const QString &candidate : candidates) {
        const QFileInfo info(candidate);
        if (info.isDir())
            return info.canonicalFilePath();
    }
    return QFileInfo(candidates.constFirst()).absoluteFilePath();
}

template<typename T>
T readSample(const char *data)
{
    T value;
    std::memcpy(&value, data, sizeof(value));
    return value;
}
}

MediaController::MediaController(QObject *parent, bool autoPlay, const QString &settingsApplication,
                                 bool mediaProcessingEnabled)
    : QObject(parent)
    , m_player(mediaProcessingEnabled ? new QMediaPlayer(this) : nullptr)
    , m_audioOutput(mediaProcessingEnabled ? new QAudioOutput(this) : nullptr)
    , m_watcher(new QFileSystemWatcher(this))
    , m_rescanTimer(new QTimer(this))
    , m_analysisPublishTimer(new QTimer(this))
    , m_mediaProcessingEnabled(mediaProcessingEnabled)
    , m_waveform(quietWaveform())
    , m_settingsApplication(settingsApplication)
{
    QSettings mediaSettings = settings();
    m_selectedDirectory = mediaSettings.value(QString::fromLatin1(DirectoryKey)).toString();
    if (m_selectedDirectory.isEmpty())
        m_selectedDirectory = defaultTracksDirectory();

    double storedVolume = mediaSettings.value(QString::fromLatin1(VolumeKey), 0.55).toDouble();
    if (!std::isfinite(storedVolume))
        storedVolume = 0.55;
    m_volume = std::clamp(storedVolume, 0.0, 1.0);
    m_muted = false;
    mediaSettings.remove(QString::fromLatin1(MutedKey));
    if (m_audioOutput) {
        m_audioOutput->setVolume(static_cast<float>(m_volume));
        m_audioOutput->setMuted(m_muted);
    }

    m_rescanTimer->setInterval(200);
    m_rescanTimer->setSingleShot(true);
    connect(m_rescanTimer, &QTimer::timeout, this, &MediaController::rescan);
    connect(m_watcher, &QFileSystemWatcher::directoryChanged, m_rescanTimer,
            qOverload<>(&QTimer::start));
    m_analysisPublishTimer->setInterval(50);
    connect(m_analysisPublishTimer, &QTimer::timeout, this, [this] {
        if (m_analysisPeaks.size() != m_publishedWaveformPeaks) {
            publishWaveformData();
            m_publishedWaveformPeaks = m_analysisPeaks.size();
        }
        if (m_visualizerLevels.size() != m_publishedVisualizerLevels) {
            publishVisualizerData();
            m_publishedVisualizerLevels = m_visualizerLevels.size();
        }
    });

    m_threadedAnalysis = m_mediaProcessingEnabled
        && QLibraryInfo::version() >= QVersionNumber(6, 5, 0);
    if (m_threadedAnalysis) {
        m_analysisThread = new QThread(this);
        m_analysisWorker = new QObject;
        m_analysisWorker->moveToThread(m_analysisThread);
        connect(m_analysisThread, &QThread::finished, m_analysisWorker, &QObject::deleteLater);
        m_analysisThread->start();
        QMetaObject::invokeMethod(m_analysisWorker, [this] {
            m_decoder = new QAudioDecoder;
        }, Qt::BlockingQueuedConnection);
        connect(m_decoder, &QAudioDecoder::bufferReady, m_analysisWorker, [this] {
            const QAudioBuffer buffer = m_decoder->read();
            if (!buffer.isValid() || buffer.byteCount() <= 0)
                return;
            const QByteArray pcm(static_cast<const char *>(buffer.constData<char>()),
                                 buffer.byteCount());
            QVector<float> peaks = pcmFramePeaks(pcm, buffer.format());
            const quint64 generation = m_workerAnalysisGeneration;
            const qint64 position = m_decoder->position();
            const qint64 duration = m_decoder->duration();
            QMetaObject::invokeMethod(this,
                [this, peaks = std::move(peaks), position, duration, generation] {
                    consumeDecodedPeaks(peaks, position, duration, generation);
                }, Qt::QueuedConnection);
        });
        connect(m_decoder, &QAudioDecoder::finished, m_analysisWorker, [this] {
            const quint64 generation = m_workerAnalysisGeneration;
            QMetaObject::invokeMethod(this, [this, generation] {
                if (generation == m_analysisGeneration)
                    finishWaveformAnalysis();
            }, Qt::QueuedConnection);
        });
        connect(m_decoder, qOverload<QAudioDecoder::Error>(&QAudioDecoder::error),
                m_analysisWorker, [this](QAudioDecoder::Error) {
                    const quint64 generation = m_workerAnalysisGeneration;
                    const QString message = m_decoder->errorString();
                    QMetaObject::invokeMethod(this, [this, generation, message] {
                        if (generation != m_analysisGeneration)
                            return;
                        m_analysisPublishTimer->stop();
                        setWaveformError(message.isEmpty()
                            ? QStringLiteral("Waveform analysis is unavailable.") : message);
                        if (m_analysisPeaks.isEmpty())
                            setWaveform(quietWaveform());
                    }, Qt::QueuedConnection);
                });
    }

    if (m_player) {
        m_player->setAudioOutput(m_audioOutput);
        connect(m_player, &QMediaPlayer::playbackStateChanged, this,
                &MediaController::playbackStateChanged);
        connect(m_player, &QMediaPlayer::positionChanged, this, &MediaController::positionChanged);
        connect(m_player, &QMediaPlayer::durationChanged, this, &MediaController::durationChanged);
        connect(m_player, &QMediaPlayer::mediaStatusChanged, this,
                [this](QMediaPlayer::MediaStatus status) {
                    if (status == QMediaPlayer::EndOfMedia)
                        next();
                });
        connect(m_player, &QMediaPlayer::errorOccurred, this,
                [this](QMediaPlayer::Error, const QString &message) {
                    setError(message.isEmpty()
                        ? QStringLiteral("Soundtrack playback is unavailable.") : message);
                });
    }
    if (m_audioOutput) {
        connect(m_audioOutput, &QAudioOutput::volumeChanged, this, &MediaController::volumeChanged);
        connect(m_audioOutput, &QAudioOutput::mutedChanged, this, &MediaController::mutedChanged);
    }

    rescan();
    if (autoPlay && m_mediaProcessingEnabled) {
        QTimer::singleShot(0, this, [this] {
            if (m_currentIndex >= 0)
                m_player->play();
        });
    }
}

MediaController::~MediaController()
{
    m_analysisPublishTimer->stop();
    ++m_analysisGeneration;
    if (m_threadedAnalysis && m_analysisThread && m_analysisThread->isRunning()) {
        QMetaObject::invokeMethod(m_analysisWorker, [this] {
            m_decoder->stop();
            m_decoder->setSourceDevice(nullptr);
            delete m_decoder;
            m_decoder = nullptr;
        }, Qt::BlockingQueuedConnection);
        m_analysisThread->quit();
        m_analysisThread->wait();
    } else if (m_decoder) {
        m_decoder->stop();
        m_decoder->setSourceDevice(nullptr);
    }
}

QStringList MediaController::trackTitles() const
{
    QStringList result;
    result.reserve(m_tracks.size());
    for (const Track &track : m_tracks)
        result.append(track.title);
    return result;
}

QString MediaController::currentTitle() const
{
    return m_currentIndex >= 0 && m_currentIndex < m_tracks.size()
        ? m_tracks.at(m_currentIndex).title : QString();
}

QMediaPlayer::PlaybackState MediaController::playbackState() const
{
    return m_player ? m_player->playbackState() : QMediaPlayer::StoppedState;
}

qint64 MediaController::position() const
{
    return m_player ? m_player->position() : 0;
}

qint64 MediaController::duration() const
{
    return m_player ? m_player->duration() : 0;
}

double MediaController::volume() const
{
    return m_audioOutput ? m_audioOutput->volume() : m_volume;
}

bool MediaController::muted() const
{
    return m_audioOutput ? m_audioOutput->isMuted() : m_muted;
}

void MediaController::setVolume(double volume)
{
    if (!std::isfinite(volume))
        volume = 0.0;
    const float clamped = static_cast<float>(std::clamp(volume, 0.0, 1.0));
    if (qFuzzyCompare(this->volume(), static_cast<double>(clamped)))
        return;
    if (m_audioOutput)
        m_audioOutput->setVolume(clamped);
    else {
        m_volume = clamped;
        emit volumeChanged();
    }
    QSettings mediaSettings = settings();
    mediaSettings.setValue(QString::fromLatin1(VolumeKey), this->volume());
}

void MediaController::setMuted(bool muted)
{
    if (this->muted() == muted)
        return;
    if (m_audioOutput)
        m_audioOutput->setMuted(muted);
    else {
        m_muted = muted;
        emit mutedChanged();
    }
}

void MediaController::playPause()
{
    if (!m_player)
        return;
    if (m_player->playbackState() == QMediaPlayer::PlayingState)
        m_player->pause();
    else
        m_player->play();
}

void MediaController::previous()
{
    const int target = indexForPrevious(m_currentIndex, m_tracks.size(), position());
    if (target < 0)
        return;
    if (target == m_currentIndex) {
        if (m_player)
            m_player->setPosition(0);
        return;
    }
    activateTrack(target, true);
}

void MediaController::next()
{
    const int target = indexForNext(m_currentIndex, m_tracks.size());
    if (target >= 0)
        activateTrack(target, true);
}

void MediaController::selectTrack(int index)
{
    if (index < 0 || index >= m_tracks.size()) {
        setError(QStringLiteral("The selected track is no longer available."));
        return;
    }
    activateTrack(index, true);
}

void MediaController::setDirectory(const QString &pathOrUrl)
{
    const QString input = pathOrUrl.trimmed();
    QString path = input.isEmpty() ? defaultTracksDirectory() : QString();
    if (!input.isEmpty()) {
        const QUrl url(input);
        if (url.isLocalFile())
            path = url.toLocalFile();
        else if (url.scheme().isEmpty())
            path = input;
        else {
            setError(QStringLiteral("The music directory must be a local folder."));
            return;
        }
        path = QFileInfo(path).absoluteFilePath();
        const QString canonical = QFileInfo(path).canonicalFilePath();
        if (!canonical.isEmpty())
            path = canonical;
    }

    if (m_selectedDirectory == path) {
        rescan();
        return;
    }
    m_selectedDirectory = path;
    QSettings mediaSettings = settings();
    mediaSettings.setValue(QString::fromLatin1(DirectoryKey), m_selectedDirectory);
    emit selectedDirectoryChanged();
    rescan();
}

void MediaController::rescan()
{
    QSettings mediaSettings = settings();
    const QString oldPath = currentCanonicalPath();
    const QString preservePath = oldPath.isEmpty()
        ? mediaSettings.value(QString::fromLatin1(CurrentTrackKey)).toString() : oldPath;
    const int oldIndex = m_currentIndex;
    const QStringList oldTitles = trackTitles();
    const bool wasPlaying = playbackState() == QMediaPlayer::PlayingState;

    QVector<Track> tracks = scanDirectory();
    if (tracks.isEmpty()) {
        m_tracks.clear();
        m_currentIndex = -1;
        updateWatcher();
        if (!oldTitles.isEmpty())
            emit tracksChanged();
        if (oldIndex >= 0)
            emit currentTrackChanged();
        mediaSettings.remove(QString::fromLatin1(CurrentTrackKey));
        if (m_player) {
            m_player->stop();
            m_player->setSource({});
        }
        startWaveformAnalysis();
        return;
    }

    int target = -1;
    for (int i = 0; i < tracks.size(); ++i) {
        if (tracks.at(i).canonicalPath == preservePath) {
            target = i;
            break;
        }
    }
    if (target < 0)
        target = oldIndex >= 0 ? std::min(oldIndex, static_cast<int>(tracks.size()) - 1) : 0;

    const QString newPath = tracks.at(target).canonicalPath;
    m_tracks = std::move(tracks);
    const bool sourceChanged = oldPath != newPath;
    const bool trackChanged = oldIndex != target || sourceChanged;
    m_currentIndex = target;

    updateWatcher();
    if (oldTitles != trackTitles())
        emit tracksChanged();
    if (trackChanged)
        emit currentTrackChanged();

    mediaSettings.setValue(QString::fromLatin1(CurrentTrackKey), newPath);
    if (sourceChanged) {
        setError({});
        if (m_mediaProcessingEnabled) {
            m_player->setSource(m_tracks.at(m_currentIndex).source);
            startWaveformAnalysis();
            if (wasPlaying)
                m_player->play();
        }
    }
}

void MediaController::clearError()
{
    setError({});
}

bool MediaController::isSupportedFileName(const QString &fileName)
{
    static const QStringList extensions = {
        QStringLiteral("oga"), QStringLiteral("ogg"), QStringLiteral("opus"),
        QStringLiteral("mp3"), QStringLiteral("flac"), QStringLiteral("wav"),
        QStringLiteral("m4a"), QStringLiteral("aac")
    };
    return extensions.contains(QFileInfo(fileName).suffix(), Qt::CaseInsensitive);
}

int MediaController::indexForPrevious(int currentIndex, int trackCount, qint64 position)
{
    if (trackCount <= 0 || currentIndex < 0 || currentIndex >= trackCount)
        return -1;
    if (position >= 3000)
        return currentIndex;
    return (currentIndex + trackCount - 1) % trackCount;
}

int MediaController::indexForNext(int currentIndex, int trackCount)
{
    if (trackCount <= 0 || currentIndex < 0 || currentIndex >= trackCount)
        return -1;
    return (currentIndex + 1) % trackCount;
}

QVector<float> MediaController::pcmFramePeaks(const QByteArray &pcm, const QAudioFormat &format)
{
    const int channels = format.channelCount();
    int bytesPerSample = 0;
    switch (format.sampleFormat()) {
    case QAudioFormat::UInt8: bytesPerSample = 1; break;
    case QAudioFormat::Int16: bytesPerSample = 2; break;
    case QAudioFormat::Int32:
    case QAudioFormat::Float: bytesPerSample = 4; break;
    default: return {};
    }
    if (channels <= 0 || pcm.isEmpty())
        return {};

    const int frameBytes = channels * bytesPerSample;
    const int frames = pcm.size() / frameBytes;
    QVector<float> result;
    result.reserve(frames);
    const char *data = pcm.constData();
    for (int frame = 0; frame < frames; ++frame) {
        float peak = 0.0f;
        for (int channel = 0; channel < channels; ++channel) {
            const char *sample = data + frame * frameBytes + channel * bytesPerSample;
            float value = 0.0f;
            switch (format.sampleFormat()) {
            case QAudioFormat::UInt8:
                value = (static_cast<unsigned char>(*sample) - 128.0f) / 128.0f;
                break;
            case QAudioFormat::Int16:
                value = readSample<qint16>(sample) / 32768.0f;
                break;
            case QAudioFormat::Int32:
                value = static_cast<float>(readSample<qint32>(sample) / 2147483648.0);
                break;
            case QAudioFormat::Float:
                value = readSample<float>(sample);
                break;
            default:
                break;
            }
            if (std::isfinite(value))
                peak = std::max(peak, std::min(1.0f, std::abs(value)));
        }
        result.append(peak);
    }
    return result;
}

QVariantList MediaController::compactEnvelope(const QVector<float> &peaks, int bucketCount)
{
    QVariantList result;
    if (peaks.isEmpty() || bucketCount <= 0)
        return result;
    const int buckets = std::min(bucketCount, static_cast<int>(peaks.size()));
    result.reserve(buckets);
    for (int bucket = 0; bucket < buckets; ++bucket) {
        const int begin = bucket * peaks.size() / buckets;
        const int end = (bucket + 1) * peaks.size() / buckets;
        float peak = 0.0f;
        for (int i = begin; i < end; ++i) {
            const float value = std::abs(peaks.at(i));
            if (std::isfinite(value))
                peak = std::max(peak, std::min(1.0f, value));
        }
        result.append(peak);
    }
    return result;
}

QVector<MediaController::Track> MediaController::scanDirectory() const
{
    QVector<Track> result;
    const QDir directory(m_selectedDirectory);
    if (m_selectedDirectory.isEmpty() || !directory.exists())
        return result;

    const QFileInfoList entries = directory.entryInfoList(
        QDir::Files | QDir::Readable | QDir::NoDotAndDotDot, QDir::NoSort);
    for (const QFileInfo &entry : entries) {
        if (!entry.isFile() || !entry.isReadable() || !isSupportedFileName(entry.fileName()))
            continue;
        QString canonicalPath = entry.canonicalFilePath();
        if (canonicalPath.isEmpty())
            canonicalPath = entry.absoluteFilePath();
        result.append({entry.completeBaseName(), canonicalPath,
                       QUrl::fromLocalFile(entry.absoluteFilePath())});
    }

    QCollator collator(QLocale::English);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    std::sort(result.begin(), result.end(), [&collator](const Track &left, const Track &right) {
        const int titleOrder = collator.compare(left.title, right.title);
        if (titleOrder != 0)
            return titleOrder < 0;
        return left.canonicalPath < right.canonicalPath;
    });
    return result;
}

void MediaController::updateWatcher()
{
    const QStringList watched = m_watcher->directories();
    if (!watched.isEmpty())
        m_watcher->removePaths(watched);
    if (!m_selectedDirectory.isEmpty() && QFileInfo(m_selectedDirectory).isDir())
        m_watcher->addPath(m_selectedDirectory);
}

void MediaController::activateTrack(int index, bool play)
{
    if (index < 0 || index >= m_tracks.size())
        return;
    const bool changed = m_currentIndex != index
        || (m_mediaProcessingEnabled && m_player->source() != m_tracks.at(index).source);
    m_currentIndex = index;
    if (changed)
        emit currentTrackChanged();

    QSettings mediaSettings = settings();
    mediaSettings.setValue(QString::fromLatin1(CurrentTrackKey), currentCanonicalPath());
    setError({});
    if (!m_mediaProcessingEnabled)
        return;
    m_player->setSource(m_tracks.at(index).source);
    startWaveformAnalysis();
    if (play)
        m_player->play();
}

void MediaController::startWaveformAnalysis()
{
    if (!m_mediaProcessingEnabled)
        return;

    m_analysisPublishTimer->stop();
    const quint64 generation = ++m_analysisGeneration;
    m_analysisPeaks.clear();
    m_visualizerLevels.clear();
    m_analysisChunkFrames = 0;
    m_analysisChunkPeak = 0.0f;
    m_visualizerChunkFrames = 0;
    m_visualizerSumSquares = 0.0;
    m_publishedWaveformPeaks = 0;
    m_publishedVisualizerLevels = 0;
    m_analysisPosition = 0;
    m_analysisDuration = 0;
    setWaveformError({});
    setWaveform(quietWaveform());
    setVisualizerData({});

    if (m_currentIndex < 0 || m_currentIndex >= m_tracks.size())
        return;
    const Track &track = m_tracks.at(m_currentIndex);
    m_analysisPublishTimer->start();
    if (m_threadedAnalysis) {
        QMetaObject::invokeMethod(m_analysisWorker, [this, generation, source = track.source] {
            m_workerAnalysisGeneration = generation;
            m_decoder->stop();
            m_decoder->setSource(source);
            m_decoder->start();
        }, Qt::QueuedConnection);
    } else {
        if (m_decoder) {
            disconnect(m_decoder, nullptr, this, nullptr);
            m_decoder->stop();
            m_decoder->setSourceDevice(nullptr);
            delete m_decoder;
        }
        m_decoder = new QAudioDecoder(this);
        QAudioDecoder *decoder = m_decoder;
        connect(decoder, &QAudioDecoder::bufferReady, this, [this, decoder, generation] {
            if (generation != m_analysisGeneration || decoder != m_decoder)
                return;
            const QAudioBuffer buffer = decoder->read();
            if (!buffer.isValid() || buffer.byteCount() <= 0)
                return;
            const QByteArray pcm(static_cast<const char *>(buffer.constData<char>()),
                                 buffer.byteCount());
            consumeDecodedPeaks(pcmFramePeaks(pcm, buffer.format()), decoder->position(),
                                decoder->duration(), generation);
        });
        connect(decoder, &QAudioDecoder::finished, this, [this, decoder, generation] {
            if (generation == m_analysisGeneration && decoder == m_decoder)
                finishWaveformAnalysis();
        });
        connect(decoder, qOverload<QAudioDecoder::Error>(&QAudioDecoder::error), this,
                [this, decoder, generation](QAudioDecoder::Error) {
                    if (generation != m_analysisGeneration || decoder != m_decoder)
                        return;
                    m_analysisPublishTimer->stop();
                    const QString message = decoder->errorString();
                    setWaveformError(message.isEmpty()
                        ? QStringLiteral("Waveform analysis is unavailable.") : message);
                    if (m_analysisPeaks.isEmpty())
                        setWaveform(quietWaveform());
                });
        decoder->setSource(track.source);
        decoder->start();
    }
}

void MediaController::consumeDecodedPeaks(const QVector<float> &framePeaks, qint64 position,
                                          qint64 duration, quint64 generation)
{
    if (generation != m_analysisGeneration)
        return;
    m_analysisPosition = position;
    m_analysisDuration = duration;
    for (float peak : framePeaks) {
        m_analysisChunkPeak = std::max(m_analysisChunkPeak, peak);
        if (++m_analysisChunkFrames == AnalysisChunkFrames) {
            m_analysisPeaks.append(m_analysisChunkPeak);
            m_analysisChunkFrames = 0;
            m_analysisChunkPeak = 0.0f;
        }
        m_visualizerSumSquares += static_cast<double>(peak) * peak;
        if (++m_visualizerChunkFrames == VisualizerChunkFrames) {
            m_visualizerLevels.append(static_cast<float>(
                std::sqrt(m_visualizerSumSquares / m_visualizerChunkFrames)));
            m_visualizerChunkFrames = 0;
            m_visualizerSumSquares = 0.0;
        }
    }
}

void MediaController::finishWaveformAnalysis()
{
    m_analysisPublishTimer->stop();
    if (m_analysisChunkFrames > 0) {
        m_analysisPeaks.append(m_analysisChunkPeak);
        m_analysisChunkFrames = 0;
        m_analysisChunkPeak = 0.0f;
    }
    if (!m_analysisPeaks.isEmpty())
        publishWaveformData(true);
    else if (m_waveformError.isEmpty())
        setWaveformError(QStringLiteral("No waveform samples were decoded."));

    if (m_visualizerChunkFrames > 0) {
        m_visualizerLevels.append(static_cast<float>(
            std::sqrt(m_visualizerSumSquares / m_visualizerChunkFrames)));
        m_visualizerChunkFrames = 0;
        m_visualizerSumSquares = 0.0;
    }
    publishVisualizerData();
    m_publishedWaveformPeaks = m_analysisPeaks.size();
    m_publishedVisualizerLevels = m_visualizerLevels.size();
}

void MediaController::publishWaveformData(bool complete)
{
    if (m_analysisPeaks.isEmpty())
        return;
    QVariantList waveform;
    const qint64 totalDuration = m_analysisDuration > 0 ? m_analysisDuration : duration();
    if (!complete && totalDuration > 0) {
        const double progress = std::clamp(
            static_cast<double>(m_analysisPosition) / totalDuration, 0.0, 1.0);
        const int decodedBuckets = std::clamp(
            static_cast<int>(std::ceil(progress * WaveformBuckets)), 1, WaveformBuckets);
        waveform = compactEnvelope(m_analysisPeaks, decodedBuckets);
        waveform.reserve(WaveformBuckets);
        while (waveform.size() < WaveformBuckets)
            waveform.append(0.0f);
    } else {
        waveform = compactEnvelope(m_analysisPeaks, WaveformBuckets);
    }
    setWaveform(waveform);
}

void MediaController::publishVisualizerData()
{
    if (m_visualizerLevels.isEmpty())
        return;
    QVariantList levels = compactEnvelope(m_visualizerLevels, VisualizerMaximumSamples);
    float maximum = 0.0f;
    for (const QVariant &level : levels)
        maximum = std::max(maximum, level.toFloat());
    if (maximum > 0.0f) {
        for (QVariant &level : levels)
            level = std::clamp(level.toFloat() / maximum, 0.0f, 1.0f);
    }
    setVisualizerData(levels);
}

void MediaController::setError(const QString &error)
{
    const QString clean = cleanError(error);
    if (m_error == clean)
        return;
    m_error = clean;
    emit errorChanged();
}

void MediaController::setWaveformError(const QString &error)
{
    const QString clean = cleanError(error);
    if (m_waveformError == clean)
        return;
    m_waveformError = clean;
    emit waveformErrorChanged();
}

void MediaController::setWaveform(const QVariantList &waveform)
{
    if (m_waveform == waveform)
        return;
    m_waveform = waveform;
    emit waveformChanged();
}

void MediaController::setVisualizerData(const QVariantList &data)
{
    if (m_visualizerData == data)
        return;
    m_visualizerData = data;
    emit visualizerDataChanged();
}

QString MediaController::currentCanonicalPath() const
{
    return m_currentIndex >= 0 && m_currentIndex < m_tracks.size()
        ? m_tracks.at(m_currentIndex).canonicalPath : QString();
}

QSettings MediaController::settings() const
{
    return QSettings(QString::fromLatin1(SettingsOrganization), m_settingsApplication);
}
