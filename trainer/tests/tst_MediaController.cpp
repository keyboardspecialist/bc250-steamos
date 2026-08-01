#include "MediaController.h"

#include <QDataStream>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrl>
#include <QtTest>

#include <cmath>
#include <limits>

class MediaControllerTest final : public QObject
{
    Q_OBJECT

private:
    static void writeWav(const QString &path, const QVector<qint16> &samples = {0, 1000, -1000, 2000})
    {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QDataStream stream(&file);
        stream.setByteOrder(QDataStream::LittleEndian);
        const quint32 dataSize = static_cast<quint32>(samples.size() * sizeof(qint16));
        stream.writeRawData("RIFF", 4);
        stream << quint32(36 + dataSize);
        stream.writeRawData("WAVEfmt ", 8);
        stream << quint32(16) << quint16(1) << quint16(1) << quint32(8000)
               << quint32(16000) << quint16(2) << quint16(16);
        stream.writeRawData("data", 4);
        stream << dataSize;
        for (qint16 sample : samples)
            stream << sample;
        file.close();
    }

    static void writeFile(const QString &path)
    {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("not audio");
    }

    static void appendInt16(QByteArray &data, qint16 value)
    {
        data.append(reinterpret_cast<const char *>(&value), sizeof(value));
    }

    static void appendInt32(QByteArray &data, qint32 value)
    {
        data.append(reinterpret_cast<const char *>(&value), sizeof(value));
    }

private slots:
    void initTestCase()
    {
        QVERIFY(m_settingsRoot.isValid());
        QStandardPaths::setTestModeEnabled(true);
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_settingsRoot.path());
        clearSettings();
    }

    void cleanup()
    {
        clearSettings();
    }

    void scansSupportedFilesWithoutRecursionInNaturalOrder()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeWav(directory.filePath(QStringLiteral("track10.wav")));
        writeWav(directory.filePath(QStringLiteral("track2.WAV")));
        writeFile(directory.filePath(QStringLiteral("track3.txt")));
        QVERIFY(QDir(directory.path()).mkdir(QStringLiteral("nested")));
        writeWav(directory.filePath(QStringLiteral("nested/track1.wav")));

        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(QUrl::fromLocalFile(directory.path()).toString());
        QCOMPARE(controller.trackTitles(), QStringList({QStringLiteral("track2"), QStringLiteral("track10")}));
    }

    void acceptsEverySupportedExtensionCaseInsensitively()
    {
        const QStringList supported = {
            QStringLiteral("a.OGA"), QStringLiteral("b.ogg"), QStringLiteral("c.OpUs"),
            QStringLiteral("d.MP3"), QStringLiteral("e.flac"), QStringLiteral("f.WAV"),
            QStringLiteral("g.m4a"), QStringLiteral("h.AAC")
        };
        for (const QString &name : supported)
            QVERIFY(MediaController::isSupportedFileName(name));
        QVERIFY(!MediaController::isSupportedFileName(QStringLiteral("audio.wav.txt")));
        QVERIFY(!MediaController::isSupportedFileName(QStringLiteral("wav")));
    }

    void leavesEmptyDirectoryEmpty()
    {
        QTemporaryDir directory;
        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        QVERIFY(controller.trackTitles().isEmpty());
        QCOMPARE(controller.currentIndex(), -1);
        QVERIFY(controller.currentTitle().isEmpty());
    }

    void preservesCurrentCanonicalPathAcrossRescan()
    {
        QTemporaryDir directory;
        writeWav(directory.filePath(QStringLiteral("song2.wav")));
        writeWav(directory.filePath(QStringLiteral("song10.wav")));
        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        controller.selectTrack(1);
        QCOMPARE(controller.currentTitle(), QStringLiteral("song10"));

        writeWav(directory.filePath(QStringLiteral("song1.wav")));
        controller.rescan();
        QCOMPARE(controller.currentTitle(), QStringLiteral("song10"));
        QCOMPARE(controller.currentIndex(), 2);
    }

    void selectsTrackAtDeletedIndexThenFallsBack()
    {
        QTemporaryDir directory;
        const QString first = directory.filePath(QStringLiteral("song1.wav"));
        const QString second = directory.filePath(QStringLiteral("song2.wav"));
        const QString third = directory.filePath(QStringLiteral("song3.wav"));
        writeWav(first);
        writeWav(second);
        writeWav(third);
        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        controller.selectTrack(1);

        QVERIFY(QFile::remove(second));
        controller.rescan();
        QCOMPARE(controller.currentIndex(), 1);
        QCOMPARE(controller.currentTitle(), QStringLiteral("song3"));

        QVERIFY(QFile::remove(first));
        QVERIFY(QFile::remove(third));
        controller.rescan();
        QVERIFY(controller.trackTitles().isEmpty());
        QCOMPARE(controller.currentIndex(), -1);
    }

    void watcherDebouncesDirectoryChanges()
    {
        QTemporaryDir directory;
        writeWav(directory.filePath(QStringLiteral("song1.wav")));
        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        QCOMPARE(controller.trackTitles().size(), 1);

        writeWav(directory.filePath(QStringLiteral("song2.wav")));
        QTRY_COMPARE_WITH_TIMEOUT(controller.trackTitles().size(), 2, 3000);
    }

    void navigationWrapsAndPreviousRestartsAfterThreeSeconds()
    {
        QCOMPARE(MediaController::indexForPrevious(0, 3, 0), 2);
        QCOMPARE(MediaController::indexForPrevious(1, 3, 2999), 0);
        QCOMPARE(MediaController::indexForPrevious(1, 3, 3000), 1);
        QCOMPARE(MediaController::indexForNext(2, 3), 0);
        QCOMPARE(MediaController::indexForNext(0, 0), -1);

        QTemporaryDir directory;
        writeWav(directory.filePath(QStringLiteral("song1.wav")));
        writeWav(directory.filePath(QStringLiteral("song2.wav")));
        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        controller.previous();
        QCOMPARE(controller.currentIndex(), 1);
        controller.next();
        QCOMPARE(controller.currentIndex(), 0);
    }

    void clampsAndPersistsSettingsWithoutPersistingMute()
    {
        QTemporaryDir directory;
        writeWav(directory.filePath(QStringLiteral("song.wav")));
        {
            MediaController controller(nullptr, false, settingsApplication(), false);
            controller.setVolume(-2.0);
            QCOMPARE(controller.volume(), 0.0);
            controller.setVolume(4.0);
            controller.setMuted(true);
            controller.setDirectory(directory.path());
            QCOMPARE(controller.volume(), 1.0);
            QVERIFY(controller.muted());
        }

        QSettings settings(QStringLiteral("keyboardspecialist"), settingsApplication());
        settings.sync();
        const QString canonicalDirectory = QFileInfo(directory.path()).canonicalFilePath();
        QCOMPARE(settings.value(QStringLiteral("audio/volume")).toDouble(), 1.0);
        QVERIFY(!settings.contains(QStringLiteral("audio/muted")));
        QCOMPARE(settings.value(QStringLiteral("audio/directory")).toString(), canonicalDirectory);
        QCOMPARE(QFileInfo(settings.value(QStringLiteral("audio/currentTrack")).toString()).canonicalFilePath(),
                 QFileInfo(directory.filePath(QStringLiteral("song.wav"))).canonicalFilePath());

        settings.setValue(QStringLiteral("audio/muted"), true);
        settings.sync();
        MediaController restored(nullptr, false, settingsApplication(), false);
        QCOMPARE(restored.volume(), 1.0);
        QVERIFY(!restored.muted());
        QCOMPARE(restored.selectedDirectory(), canonicalDirectory);
        QCOMPARE(restored.currentTitle(), QStringLiteral("song"));

        QSettings cleanedSettings(QStringLiteral("keyboardspecialist"), settingsApplication());
        cleanedSettings.sync();
        QVERIFY(!cleanedSettings.contains(QStringLiteral("audio/muted")));
    }

    void convertsPcmFormatsAndCombinesChannels()
    {
        QAudioFormat format;
        format.setSampleRate(8000);
        format.setChannelCount(2);
        format.setSampleFormat(QAudioFormat::Int16);
        QByteArray int16Data;
        appendInt16(int16Data, 0);
        appendInt16(int16Data, 16384);
        appendInt16(int16Data, -32768);
        appendInt16(int16Data, 100);
        const QVector<float> int16Peaks = MediaController::pcmFramePeaks(int16Data, format);
        QCOMPARE(int16Peaks.size(), 2);
        QVERIFY(std::abs(int16Peaks.at(0) - 0.5f) < 0.0001f);
        QCOMPARE(int16Peaks.at(1), 1.0f);

        format.setChannelCount(1);
        format.setSampleFormat(QAudioFormat::UInt8);
        const QVector<float> uint8Peaks = MediaController::pcmFramePeaks(
            QByteArray::fromRawData("\x80\x00\xff", 3), format);
        QCOMPARE(uint8Peaks.size(), 3);
        QCOMPARE(uint8Peaks.at(0), 0.0f);
        QCOMPARE(uint8Peaks.at(1), 1.0f);
        QVERIFY(std::abs(uint8Peaks.at(2) - (127.0f / 128.0f)) < 0.0001f);

        format.setSampleFormat(QAudioFormat::Int32);
        QByteArray int32Data;
        appendInt32(int32Data, std::numeric_limits<qint32>::min());
        appendInt32(int32Data, 1073741824);
        QCOMPARE(MediaController::pcmFramePeaks(int32Data, format), QVector<float>({1.0f, 0.5f}));

        format.setSampleFormat(QAudioFormat::Float);
        const float values[] = {-0.25f, 1.5f};
        QByteArray floatData(reinterpret_cast<const char *>(values), sizeof(values));
        QCOMPARE(MediaController::pcmFramePeaks(floatData, format), QVector<float>({0.25f, 1.0f}));
    }

    void buildsDeterministicNormalizedEnvelope()
    {
        const QVector<float> peaks = {0.1f, -0.4f, 0.2f, 1.4f, 0.3f, 0.8f};
        const QVariantList envelope = MediaController::compactEnvelope(peaks, 3);
        QCOMPARE(envelope.size(), 3);
        QVERIFY(std::abs(envelope.at(0).toFloat() - 0.4f) < 0.0001f);
        QCOMPARE(envelope.at(1).toFloat(), 1.0f);
        QVERIFY(std::abs(envelope.at(2).toFloat() - 0.8f) < 0.0001f);
        QVERIFY(MediaController::compactEnvelope({}, 10).isEmpty());
    }

    void disablesMediaProcessingForStartupSmokeTests()
    {
        QTemporaryDir directory;
        writeWav(directory.filePath(QStringLiteral("smoke.wav")));

        MediaController controller(nullptr, false, settingsApplication(), false);
        controller.setDirectory(directory.path());
        QTest::qWait(100);

        QCOMPARE(controller.trackTitles(), QStringList({QStringLiteral("smoke")}));
        QCOMPARE(controller.currentTitle(), QStringLiteral("smoke"));
        QVERIFY(controller.waveform().isEmpty());
        QVERIFY(controller.visualizerData().isEmpty());
        QVERIFY(controller.waveformError().isEmpty());
    }

    void decodesGeneratedWavWithoutBlockingPlaybackState()
    {
        QTemporaryDir directory;
        QVector<qint16> samples;
        samples.reserve(2048);
        for (int i = 0; i < 2048; ++i)
            samples.append(i % 64 < 32 ? 12000 : -12000);
        writeWav(directory.filePath(QStringLiteral("waveform.wav")), samples);

        MediaController controller(nullptr, false, settingsApplication());
        controller.setDirectory(directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(!controller.waveform().isEmpty(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(!controller.visualizerData().isEmpty(), 5000);
        QCOMPARE(controller.currentTitle(), QStringLiteral("waveform"));
        QVERIFY(controller.error().isEmpty());
    }

    void decoderFailureIsNonfatal()
    {
        QTemporaryDir directory;
        writeFile(directory.filePath(QStringLiteral("broken.wav")));

        MediaController controller(nullptr, false, settingsApplication());
        controller.setDirectory(directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(!controller.waveformError().isEmpty(), 5000);
        QCOMPARE(controller.currentTitle(), QStringLiteral("broken"));
        QCOMPARE(controller.currentIndex(), 0);
        QVERIFY(controller.waveform().isEmpty());
        QVERIFY(controller.visualizerData().isEmpty());
    }

private:
    void clearSettings()
    {
        QSettings settings(QStringLiteral("keyboardspecialist"), settingsApplication());
        settings.clear();
        settings.sync();
    }

    static QString settingsApplication()
    {
        return QStringLiteral("bc250-trainer-tests-%1").arg(QCoreApplication::applicationPid());
    }

    QTemporaryDir m_settingsRoot;
};

QTEST_GUILESS_MAIN(MediaControllerTest)
#include "tst_MediaController.moc"
