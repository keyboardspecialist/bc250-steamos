#pragma once

#include <QAudioFormat>
#include <QByteArray>
#include <QMediaPlayer>
#include <QObject>
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVector>

class QAudioDecoder;
class QAudioOutput;
class QFileSystemWatcher;
class QSettings;
class QTimer;

class MediaController final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QStringList trackTitles READ trackTitles NOTIFY tracksChanged)
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY currentTrackChanged)
    Q_PROPERTY(QString currentTitle READ currentTitle NOTIFY currentTrackChanged)
    Q_PROPERTY(QMediaPlayer::PlaybackState playbackState READ playbackState NOTIFY playbackStateChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackStateChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    Q_PROPERTY(QString selectedDirectory READ selectedDirectory WRITE setDirectory NOTIFY selectedDirectoryChanged)
    Q_PROPERTY(QVariantList waveform READ waveform NOTIFY waveformChanged)
    Q_PROPERTY(QVariantList waveformData READ waveform NOTIFY waveformChanged)
    Q_PROPERTY(QVariantList visualizerData READ visualizerData NOTIFY visualizerDataChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString waveformError READ waveformError NOTIFY waveformErrorChanged)

public:
    explicit MediaController(QObject *parent = nullptr, bool autoPlay = true,
                             const QString &settingsApplication = QStringLiteral("bc250-cracktro"),
                             bool mediaProcessingEnabled = true);
    ~MediaController() override;

    QStringList trackTitles() const;
    int currentIndex() const { return m_currentIndex; }
    QString currentTitle() const;
    QMediaPlayer::PlaybackState playbackState() const;
    bool playing() const { return playbackState() == QMediaPlayer::PlayingState; }
    qint64 position() const;
    qint64 duration() const;
    double volume() const;
    bool muted() const;
    QString selectedDirectory() const { return m_selectedDirectory; }
    QVariantList waveform() const { return m_waveform; }
    QVariantList visualizerData() const { return m_visualizerData; }
    QString error() const { return m_error; }
    QString waveformError() const { return m_waveformError; }

    void setVolume(double volume);
    void setMuted(bool muted);

    Q_INVOKABLE void playPause();
    Q_INVOKABLE void togglePlayback() { playPause(); }
    Q_INVOKABLE void previous();
    Q_INVOKABLE void next();
    Q_INVOKABLE void selectTrack(int index);
    Q_INVOKABLE void setDirectory(const QString &pathOrUrl);
    Q_INVOKABLE void rescan();
    Q_INVOKABLE void clearError();

    static bool isSupportedFileName(const QString &fileName);
    static int indexForPrevious(int currentIndex, int trackCount, qint64 position);
    static int indexForNext(int currentIndex, int trackCount);
    static QVector<float> pcmFramePeaks(const QByteArray &pcm, const QAudioFormat &format);
    static QVariantList compactEnvelope(const QVector<float> &peaks, int bucketCount);

signals:
    void tracksChanged();
    void currentTrackChanged();
    void playbackStateChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void mutedChanged();
    void selectedDirectoryChanged();
    void waveformChanged();
    void visualizerDataChanged();
    void errorChanged();
    void waveformErrorChanged();

private:
    struct Track {
        QString title;
        QString canonicalPath;
        QUrl source;
    };

    QVector<Track> scanDirectory() const;
    void updateWatcher();
    void activateTrack(int index, bool play);
    void startWaveformAnalysis();
    void consumeDecodedBuffer();
    void finishWaveformAnalysis();
    void setError(const QString &error);
    void setWaveformError(const QString &error);
    void setWaveform(const QVariantList &waveform);
    void setVisualizerData(const QVariantList &data);
    QString currentCanonicalPath() const;
    QSettings settings() const;

    QMediaPlayer *m_player = nullptr;
    QAudioOutput *m_audioOutput = nullptr;
    QAudioDecoder *m_decoder = nullptr;
    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_rescanTimer = nullptr;
    bool m_mediaProcessingEnabled = true;
    QVector<Track> m_tracks;
    QVector<float> m_analysisPeaks;
    QVector<float> m_visualizerLevels;
    QVariantList m_waveform;
    QVariantList m_visualizerData;
    QString m_selectedDirectory;
    QString m_settingsApplication;
    QString m_error;
    QString m_waveformError;
    double m_volume = 0.55;
    bool m_muted = false;
    int m_currentIndex = -1;
    int m_analysisChunkFrames = 0;
    float m_analysisChunkPeak = 0.0f;
    int m_visualizerChunkFrames = 0;
    double m_visualizerSumSquares = 0.0;
    qsizetype m_nextWaveformUpdate = 16;
    quint64 m_analysisGeneration = 0;
};
