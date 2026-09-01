#include "Bc250Bridge.h"

#include <QSignalSpy>
#include <QtTest>

class Bc250BridgeTest final : public QObject
{
    Q_OBJECT

private slots:
    void parsesObject()
    {
        QString error;
        const QVariantMap value = Bc250Bridge::parseJsonObject(
            QByteArrayLiteral("{\"gpu\":{\"activeMhz\":1120},\"ok\":true}"), &error);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QCOMPARE(value.value(QStringLiteral("ok")).toBool(), true);
        QCOMPARE(value.value(QStringLiteral("gpu")).toMap().value(QStringLiteral("activeMhz")).toInt(), 1120);
    }

    void rejectsMalformedAndNonObjectJson()
    {
        QString error;
        QVERIFY(Bc250Bridge::parseJsonObject(QByteArrayLiteral("[1,2]"), &error).isEmpty());
        QVERIFY(!error.isEmpty());
        QVERIFY(Bc250Bridge::parseJsonObject(QByteArrayLiteral("{"), &error).isEmpty());
        QVERIFY(!error.isEmpty());
    }

    void sanitizesServiceErrors()
    {
        const QString dirty = QStringLiteral(" Failure\nwith\tspacing ") + QChar(1);
        QCOMPARE(Bc250Bridge::sanitizeError(dirty), QStringLiteral("Failure with spacing"));
        QCOMPARE(Bc250Bridge::sanitizeError(QString(800, QLatin1Char('x'))).size(), 600);
    }

    void validatesOperationIds_data()
    {
        QTest::addColumn<QString>("value");
        QTest::addColumn<bool>("valid");
        QTest::newRow("lowercase") << QStringLiteral("0123456789abcdef0123456789abcdef") << true;
        QTest::newRow("uppercase") << QStringLiteral("ABCDEF0123456789ABCDEF0123456789") << true;
        QTest::newRow("short") << QStringLiteral("0123") << false;
        QTest::newRow("punctuation") << QStringLiteral("0123456789abcdef0123456789abcde-") << false;
    }

    void validatesOperationIds()
    {
        QFETCH(QString, value);
        QFETCH(bool, valid);
        QCOMPARE(Bc250Bridge::isValidOperationId(value), valid);
    }

    void rejectsOutOfBoundsBeforeMutation()
    {
        Bc250Bridge bridge(true);
        QSignalSpy busySpy(&bridge, &Bc250Bridge::busyChanged);
        bridge.setRamp(199);
        QVERIFY(!bridge.error().isEmpty());
        QVERIFY(!bridge.busy());
        QCOMPARE(busySpy.count(), 0);

        bridge.clearMessage();
        bridge.setCustomLoadTarget(80, 40);
        QVERIFY(bridge.error().contains(QStringLiteral("below maximum")));
        QVERIFY(!bridge.busy());

        bridge.clearMessage();
        bridge.setUmaSize(2048);
        QVERIFY(bridge.error().contains(QStringLiteral("not 2048")));
        QVERIFY(!bridge.busy());

        bridge.clearMessage();
        bridge.setTtmPages(65535);
        QVERIFY(bridge.error().contains(QStringLiteral("65536")));
        QVERIFY(!bridge.busy());
    }

    void mockUnlockSchemaMatchesService()
    {
        Bc250Bridge bridge(true);
        const QVariantMap unlock = bridge.cpuUnlockStatus();
        QCOMPARE(unlock.value(QStringLiteral("schemaVersion")).toInt(), 1);
        QCOMPARE(unlock.value(QStringLiteral("guard")).toMap().value(QStringLiteral("state")).toString(),
                 QStringLiteral("clear"));
        QCOMPARE(unlock.value(QStringLiteral("mode")).toString(), QStringLiteral("linux-replay"));
        QCOMPARE(unlock.value(QStringLiteral("linuxReplay")).toMap()
                     .value(QStringLiteral("service")).toMap()
                     .value(QStringLiteral("enabled")).toString(), QStringLiteral("enabled"));
        QVERIFY(unlock.value(QStringLiteral("linuxReplay")).toMap()
                    .value(QStringLiteral("enabled")).toBool());
        const QVariantMap efi = unlock.value(QStringLiteral("efi")).toMap();
        QVERIFY(!efi.value(QStringLiteral("installed")).toBool());
        QVERIFY(!efi.value(QStringLiteral("partial")).toBool());
        QVERIFY(!efi.value(QStringLiteral("bootEntryConfigured")).toBool());
        QVERIFY(!efi.value(QStringLiteral("bootEntry")).toMap()
                     .value(QStringLiteral("present")).toBool());
        QVERIFY(!efi.value(QStringLiteral("bootEntry")).toMap()
                     .value(QStringLiteral("matching")).toBool());
        QVERIFY(!efi.value(QStringLiteral("bootEntry")).toMap()
                     .value(QStringLiteral("firstInBootOrder")).toBool());
        QVERIFY(!efi.value(QStringLiteral("bootEntry")).toMap()
                     .value(QStringLiteral("effective")).toBool());
        QCOMPARE(unlock.value(QStringLiteral("actions")).toMap()
                     .value(QStringLiteral("efi-enable")).toMap()
                     .value(QStringLiteral("blockers")).toList(),
                 QVariantList{QStringLiteral("persistent-replay-enabled")});
        QVERIFY(unlock.value(QStringLiteral("actions")).toMap()
                    .contains(QStringLiteral("efi-enable")));
        QCOMPARE(unlock.value(QStringLiteral("ccxGroups")).toList().size(), 2);
    }

    void acceptsEfiUnlockAction()
    {
        Bc250Bridge bridge(true);
        bridge.cpuUnlockAction(QStringLiteral("efi-enable"));
        QVERIFY2(bridge.error().isEmpty(), qPrintable(bridge.error()));
        QVERIFY(bridge.busy());
        QVERIFY(bridge.busyLabel().contains(QStringLiteral("efi-enable")));
    }

    void rejectsUnknownUnlockAction()
    {
        Bc250Bridge bridge(true);
        bridge.cpuUnlockAction(QStringLiteral("efi-remove"));
        QVERIFY(bridge.error().contains(QStringLiteral("Unknown CPU core-unlock action")));
        QVERIFY(!bridge.busy());
    }

    void acceptsCpuMitigationsToggle()
    {
        Bc250Bridge bridge(true);
        bridge.setCpuMitigations(false);
        QVERIFY2(bridge.error().isEmpty(), qPrintable(bridge.error()));
        QVERIFY(bridge.busy());
        QVERIFY(bridge.busyLabel().contains(QStringLiteral("Disabling CPU mitigations")));
        QVERIFY(!bridge.operationCancellable());
    }

    void mockRamSchemaMatchesService()
    {
        Bc250Bridge bridge(true);
        const QVariantMap ram = bridge.snapshot().value(QStringLiteral("ram")).toMap();
        QCOMPARE(ram.value(QStringLiteral("schemaVersion")).toInt(), 1);
        QVERIFY(ram.value(QStringLiteral("available")).toBool());
        QCOMPARE(ram.value(QStringLiteral("umaLastRequestedMiB")).toInt(), 512);
        QCOMPARE(ram.value(QStringLiteral("ttmConfiguredPages")).toInt(), 3014656);
        QVERIFY(!ram.value(QStringLiteral("rebootRequired")).toBool());
    }

    void mockMeshAndAudioSchemasMatchService()
    {
        Bc250Bridge bridge(true);
        const QVariantMap mesh = bridge.meshStatus();
        QCOMPARE(mesh.value(QStringLiteral("runtimeState")).toString(), QStringLiteral("ready"));
        QCOMPARE(mesh.value(QStringLiteral("fsr4State")).toString(), QStringLiteral("ready"));
        QVERIFY(mesh.value(QStringLiteral("schedulerActive")).toBool());

        const QVariantMap audio = bridge.snapshot().value(QStringLiteral("audio")).toMap();
        QVERIFY(audio.value(QStringLiteral("available")).toBool());
        QVERIFY(audio.value(QStringLiteral("active")).toBool());
        QCOMPARE(audio.value(QStringLiteral("activeProfile")).toString(),
                 QStringLiteral("output:hdmi-ac3-surround"));
    }

    void acceptsHdmiSurroundToggle()
    {
        Bc250Bridge bridge(true);
        bridge.setHdmiSurround(false);
        QVERIFY2(bridge.error().isEmpty(), qPrintable(bridge.error()));
        QVERIFY(bridge.busy());
        QVERIFY(bridge.busyLabel().contains(QStringLiteral("Disabling HDMI surround")));
        QVERIFY(!bridge.operationCancellable());
    }
};

QTEST_GUILESS_MAIN(Bc250BridgeTest)
#include "tst_Bc250Bridge.moc"
