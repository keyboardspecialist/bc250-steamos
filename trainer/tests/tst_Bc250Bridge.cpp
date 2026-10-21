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
        bridge.setTemperatureTarget(101);
        QVERIFY(bridge.error().contains(QStringLiteral("50-100")));
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

    void telemetryOnlyPollsOnVisibleStatusPage()
    {
        Bc250Bridge bridge(true);
        QVERIFY(!bridge.statusPageActive());
        QVERIFY(bridge.telemetryHistory().isEmpty());

        bridge.setStatusPageActive(true);
        QCOMPARE(bridge.telemetryHistory().size(), 1);
        bridge.setStatusPageActive(false);
        QTest::qWait(1100);
        QCOMPARE(bridge.telemetryHistory().size(), 1);

        bridge.setVisible(false);
        bridge.setStatusPageActive(true);
        QCOMPARE(bridge.telemetryHistory().size(), 1);
        bridge.setVisible(true);
        QCOMPARE(bridge.telemetryHistory().size(), 2);
    }

    void mockGpuMutationsUpdateSnapshot()
    {
        Bc250Bridge bridge(true);

        bridge.setGpuFrequency(QStringLiteral("range"), 350, 1400);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QVariantMap gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("mode")).toString(), QStringLiteral("range"));
        QCOMPARE(gpu.value(QStringLiteral("minimum")).toInt(), 350);
        QCOMPARE(gpu.value(QStringLiteral("maximum")).toInt(), 1400);

        bridge.setGpuFrequency(QStringLiteral("adaptive"), -1, -1);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("mode")).toString(), QStringLiteral("adaptive"));
        QCOMPARE(gpu.value(QStringLiteral("minimum")).toInt(), 350);
        QCOMPARE(gpu.value(QStringLiteral("maximum")).toInt(), 1500);

        bridge.setLoadTarget(QStringLiteral("eager"));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("loadLower")).toDouble(), 0.10);
        QCOMPARE(gpu.value(QStringLiteral("loadUpper")).toDouble(), 0.40);

        bridge.setCustomLoadTarget(25, 70);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("loadLower")).toDouble(), 0.25);
        QCOMPARE(gpu.value(QStringLiteral("loadUpper")).toDouble(), 0.70);

        bridge.setTemperatureTarget(90);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("temperatureTarget")).toInt(), 90);
        QCOMPARE(gpu.value(QStringLiteral("temperatureRecovery")).toInt(), 80);

        bridge.setRamp(1200);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("climbMs")).toInt(), 1200);
    }

    void cancelledMockMutationPreservesStateAndError()
    {
        Bc250Bridge bridge(true);
        const QVariantMap before = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        bridge.setGpuFrequency(QStringLiteral("pin"), 0, 1200);
        QVERIFY(bridge.busy());
        bridge.cancelOperation();

        QVERIFY(!bridge.busy());
        QCOMPARE(bridge.operation().value(QStringLiteral("status")).toString(),
                 QStringLiteral("cancelled"));
        QCOMPARE(bridge.snapshot().value(QStringLiteral("gpu")).toMap(), before);
        QVERIFY(bridge.error().contains(QStringLiteral("cancelled")));
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
        QVERIFY(!efi.value(QStringLiteral("stateInstalled")).toBool());
        QVERIFY(!efi.value(QStringLiteral("stateValid")).toBool());
        QVERIFY(!efi.value(QStringLiteral("licenseInstalled")).toBool());
        QVERIFY(!efi.value(QStringLiteral("headersLicenseInstalled")).toBool());
        QVERIFY(!efi.value(QStringLiteral("recoveryStatePresent")).toBool());
        QVERIFY(!efi.value(QStringLiteral("recoverable")).toBool());
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

    void acceptsCpuSmtToggle()
    {
        Bc250Bridge bridge(true);
        bridge.setCpuSmtDisabled(true);
        QVERIFY2(bridge.error().isEmpty(), qPrintable(bridge.error()));
        QVERIFY(bridge.busy());
        QVERIFY(bridge.busyLabel().contains(QStringLiteral("Disabling CPU SMT")));
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

    void rejectsUnknownGameIdsAndProxies()
    {
        Bc250Bridge bridge(true);
        bridge.setFsr4Dll(QString(64, QLatin1Char('f')), true);
        QVERIFY(!bridge.busy());
        QVERIFY(bridge.error().contains(QStringLiteral("server-discovered")));
        bridge.installOptiscaler(QString(64, QLatin1Char('b')), QStringLiteral("../../evil.dll"));
        QVERIFY(!bridge.busy());
        QVERIFY(bridge.error().contains(QStringLiteral("proxy")));
        bridge.setFsr4Dll(QStringLiteral("/tmp/game.dll"), true);
        QVERIFY(!bridge.busy());
    }

    void mockGameInstallAndRollback()
    {
        Bc250Bridge bridge(true);
        const QString id(64, QLatin1Char('a'));
        bridge.setFsr4Dll(id, true);
        QVERIFY(bridge.busy());
        QVERIFY(!bridge.operationCancellable());
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        auto target = [&bridge] {
            return bridge.fsr4Inventory().value(QStringLiteral("games")).toList().first().toMap()
                .value(QStringLiteral("targets")).toList().first().toMap();
        };
        QCOMPARE(target().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
        bridge.setFsr4Dll(id, false);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(target().value(QStringLiteral("state")).toString(), QStringLiteral("available"));
        bridge.installHelixsr(id);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QVERIFY(target().value(QStringLiteral("helixsrManaged")).toBool());
        bridge.uninstallHelixsr(id);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QVERIFY(!target().value(QStringLiteral("helixsrManaged")).toBool());
    }

    void validatesWholeCurveAndResetsRamp()
    {
        Bc250Bridge bridge(true);
        bridge.gpuVoltageAction(QStringLiteral("add"), 349, 800, 0);
        QVERIFY(!bridge.busy());
        bridge.gpuVoltageAction(QStringLiteral("set"), 1500, 1051, 0);
        QVERIFY(!bridge.busy());
        bridge.gpuVoltageAction(QStringLiteral("offset"), 0, -1, 0);
        QVERIFY(!bridge.busy()); // mock 350 MHz floor is already 700 mV
        bridge.gpuVoltageAction(QStringLiteral("remove"), 350, 0, 0);
        QVERIFY(!bridge.busy()); // must retain at least two points
        bridge.gpuVoltageAction(QStringLiteral("add"), 350, 800, 0);
        QVERIFY(!bridge.busy()); // duplicate
        bridge.gpuVoltageAction(QStringLiteral("set"), 1500, 900, 999);
        QVERIFY(bridge.busy());
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        const auto gpu = bridge.snapshot().value(QStringLiteral("gpu")).toMap();
        QCOMPARE(gpu.value(QStringLiteral("safePoints")).toList().last().toMap()
            .value(QStringLiteral("voltage")).toInt(), 900);
        bridge.gpuVoltageAction(QStringLiteral("reset"), -1, -1, -1);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(bridge.snapshot().value(QStringLiteral("gpu")).toMap().value(QStringLiteral("safePoints")).toList().size(), 5);
        bridge.setRamp(1000);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        bridge.resetGpuRamp();
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(bridge.snapshot().value(QStringLiteral("gpu")).toMap().value(QStringLiteral("climbMs")).toInt(), 500);
    }

    void cecValidationAndMockState()
    {
        Bc250Bridge bridge(true);
        bridge.cecAction(QStringLiteral("shell"));
        QVERIFY(!bridge.busy());
        bridge.setCecToggle(QStringLiteral("arbitrary"), true);
        QVERIFY(!bridge.busy());
        for (const QString &name : QStringList{QString(), QString(15, QLatin1Char('a')), QStringLiteral("bad\nname"), QStringLiteral("bad\\name"), QStringLiteral("bad\"name")}) {
            bridge.setCecName(name);
            QVERIFY(!bridge.busy());
        }
        bridge.setCecName(QStringLiteral("BC250 TV"));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(bridge.snapshot().value(QStringLiteral("cec")).toMap().value(QStringLiteral("osdName")).toString(), QStringLiteral("BC250 TV"));
    }

    void compatibleMetricsAreExplicitActionsNotSampling()
    {
        Bc250Bridge bridge(true);
        const QVariantMap before = bridge.cpuUnlockStatus().value(QStringLiteral("metrics")).toMap();
        bridge.setStatusPageActive(true);
        QVERIFY(!bridge.telemetry().value(QStringLiteral("sensors")).toList().isEmpty());
        QCOMPARE(bridge.cpuUnlockStatus().value(QStringLiteral("metrics")).toMap(), before);
        bridge.cpuUnlockAction(QStringLiteral("metrics-enable"));
        QVERIFY(bridge.busy());
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(bridge.cpuUnlockStatus().value(QStringLiteral("metrics")).toMap().value(QStringLiteral("state")).toString(), QStringLiteral("compatible"));
        bridge.cpuUnlockAction(QStringLiteral("uninstall"));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.busy(), 2000);
        QCOMPARE(bridge.cpuUnlockStatus().value(QStringLiteral("metrics")).toMap().value(QStringLiteral("state")).toString(), QStringLiteral("not-installed"));
    }

    void cliHandoffRejectsCommands()
    {
        Bc250Bridge bridge(true);
        bridge.openCliSection(QStringLiteral("status; id"));
        QVERIFY(!bridge.busy());
        bridge.openCliSection(QStringLiteral("/bin/sh"));
        QVERIFY(!bridge.busy());
        QVERIFY(bridge.cliCatalog().contains(QStringLiteral("available")));
    }

    void flatpakHandoffIsUnavailableEvenInMockCatalog()
    {
        const bool wasSet = qEnvironmentVariableIsSet("FLATPAK_ID");
        const QByteArray previous = qgetenv("FLATPAK_ID");
        qputenv("FLATPAK_ID", "io.github.keyboardspecialist.bc250trainer.test");
        QVariantMap catalog;
        QString error;
        bool busy = false;
        {
            Bc250Bridge bridge(true);
            catalog = bridge.cliCatalog();
            bridge.openCliSection(QStringLiteral("menu"));
            busy = bridge.busy();
            error = bridge.error();
        }
        if (wasSet) qputenv("FLATPAK_ID", previous); else qunsetenv("FLATPAK_ID");
        QVERIFY(!catalog.value(QStringLiteral("available")).toBool());
        QVERIFY(catalog.value(QStringLiteral("reason")).toString().contains(QStringLiteral("Flatpak")));
        QVERIFY(!busy);
        QVERIFY(error.contains(QStringLiteral("Flatpak")));
    }
};

QTEST_GUILESS_MAIN(Bc250BridgeTest)
#include "tst_Bc250Bridge.moc"
