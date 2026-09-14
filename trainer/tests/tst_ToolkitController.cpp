#include "ToolkitController.h"

#include <QDir>
#include <QFile>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

class ToolkitControllerTest final : public QObject
{
    Q_OBJECT

private:
    static void writeLauncher(const QString &directory, const QByteArray &body)
    {
        QFile launcher(QDir(directory).filePath(QStringLiteral("bc250-toolkit.sh")));
        QVERIFY(launcher.open(QIODevice::WriteOnly));
        QCOMPARE(launcher.write(body), body.size());
        launcher.close();
    }

private slots:
    void allowlistMetadataIsFixed()
    {
        const QStringList expectedIds = {
            QStringLiteral("auto-base-installation"), QStringLiteral("storage-install"),
            QStringLiteral("storage-repair"),
            QStringLiteral("storage-remove"), QStringLiteral("power-install"),
            QStringLiteral("power-remove"), QStringLiteral("ram-install"),
            QStringLiteral("ram-remove"), QStringLiteral("swap-zram-install"),
            QStringLiteral("swap-zswap-install"), QStringLiteral("swap-remove"),
            QStringLiteral("compute-build"),
            QStringLiteral("compute-remove"), QStringLiteral("ac3-install"),
            QStringLiteral("ac3-remove"),
            QStringLiteral("aic-install"), QStringLiteral("aic-remove"),
            QStringLiteral("fan-install"), QStringLiteral("fan-remove"),
            QStringLiteral("audio-build"), QStringLiteral("audio-remove"),
            QStringLiteral("proton-install"), QStringLiteral("proton-update"),
            QStringLiteral("proton-remove"), QStringLiteral("graphics-setup"),
            QStringLiteral("mesh-remove"),
            QStringLiteral("decky-install"), QStringLiteral("decky-remove"),
            QStringLiteral("desktop-install"), QStringLiteral("desktop-remove"),
            QStringLiteral("coolercontrol-install"),
            QStringLiteral("coolercontrol-remove")};
        for (const QString &id : expectedIds)
            QCOMPARE(ToolkitController::operationMetadata(id).value(QStringLiteral("id")), id);
        for (const QString &removed : {QStringLiteral("cec-setup"),
                                      QStringLiteral("cec-repair"),
                                      QStringLiteral("cec-remove"),
                                      QStringLiteral("persistence-install"),
                                      QStringLiteral("persistence-remove"),
                                      QStringLiteral("mesh-setup")})
            QVERIFY(ToolkitController::operationMetadata(removed).isEmpty());

        const QVariantMap autoBase =
            ToolkitController::operationMetadata(QStringLiteral("auto-base-installation"));
        QCOMPARE(autoBase.value(QStringLiteral("title")).toString(),
                  QStringLiteral("Auto Base Toolkit Installation"));
        QCOMPARE(autoBase.value(QStringLiteral("verb")).toString(),
                  QStringLiteral("INSTALL / RESUME"));
        QVERIFY(!autoBase.contains(QStringLiteral("component")));
        QVERIFY(!autoBase.value(QStringLiteral("cancellable")).toBool());
        QVERIFY(!autoBase.value(QStringLiteral("destructive")).toBool());
        const QString autoBaseDescription = autoBase.value(QStringLiteral("description")).toString();
        QVERIFY(autoBaseDescription.contains(QStringLiteral("AMDGPU/RADV")));
        QVERIFY(autoBaseDescription.contains(QStringLiteral("power foundation")));
        QVERIFY(autoBaseDescription.contains(QStringLiteral("RAM helper")));
        QVERIFY(autoBaseDescription.contains(QStringLiteral("automatic dependencies")));
        QVERIFY(autoBaseDescription.contains(QStringLiteral("mandatory reboots")));
        QVERIFY(autoBaseDescription.contains(QStringLiteral("resumes")));

        const QVariantMap power = ToolkitController::operationMetadata(QStringLiteral("power-install"));
        QVERIFY(!power.isEmpty());
        QVERIFY(!power.value(QStringLiteral("cancellable")).toBool());
        QCOMPARE(power.value(QStringLiteral("component")).toString(), QStringLiteral("power"));
        QVERIFY(!power.value(QStringLiteral("destructive")).toBool());
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("power-remove"))
                    .value(QStringLiteral("destructive")).toBool());
        QCOMPARE(ToolkitController::operationMetadata(QStringLiteral("swap-zswap-install"))
                     .value(QStringLiteral("component")).toString(),
                 QStringLiteral("swap"));
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("swap-remove"))
                    .value(QStringLiteral("destructive")).toBool());
        QCOMPARE(ToolkitController::operationMetadata(QStringLiteral("graphics-setup"))
                     .value(QStringLiteral("component")).toString(),
                 QStringLiteral("mesh"));
        QCOMPARE(ToolkitController::operationMetadata(QStringLiteral("ac3-install"))
                     .value(QStringLiteral("component")).toString(),
                 QStringLiteral("ac3"));
        QCOMPARE(ToolkitController::operationMetadata(QStringLiteral("proton-update"))
                     .value(QStringLiteral("component")).toString(),
                 QStringLiteral("proton"));
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("ac3-remove"))
                    .value(QStringLiteral("destructive")).toBool());
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("proton-remove"))
                    .value(QStringLiteral("destructive")).toBool());
        QCOMPARE(ToolkitController::operationMetadata(QStringLiteral("coolercontrol-install"))
                     .value(QStringLiteral("component")).toString(),
                 QStringLiteral("coolercontrol"));
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("coolercontrol-remove"))
                    .value(QStringLiteral("destructive")).toBool());
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("../bc250-toolkit.sh")).isEmpty());
        QVERIFY(ToolkitController::operationMetadata(QStringLiteral("power-install extra")).isEmpty());
    }

    void reportsMissingToolkit()
    {
        QTemporaryDir parent;
        const QString missing = parent.filePath(QStringLiteral("missing"));
        ToolkitController controller(false, missing);
        QVERIFY(!controller.available());
        QCOMPARE(controller.toolkitPath(), QDir::cleanPath(missing));
        QVERIFY(!controller.error().isEmpty());
    }

    void parsesBoundedJson()
    {
        QString error;
        const QVariantMap inventory = ToolkitController::parseInventoryJson(
            QByteArrayLiteral("{\"schemaVersion\":1,\"components\":[{\"id\":\"power\",\"label\":\"Power\",\"state\":\"installed\"}]}"), &error);
        QVERIFY(error.isEmpty());
        QCOMPARE(inventory.value(QStringLiteral("schemaVersion")).toInt(), 1);
        QCOMPARE(inventory.value(QStringLiteral("components")).toList().size(), 1);

        QVERIFY(ToolkitController::parseInventoryJson(QByteArrayLiteral("[]"), &error).isEmpty());
        QVERIFY(!error.isEmpty());
        QVERIFY(ToolkitController::parseInventoryJson(
                    QByteArrayLiteral("{\"schemaVersion\":2,\"components\":[]}"), &error).isEmpty());
        QVERIFY(!error.isEmpty());
        QVERIFY(ToolkitController::parseInventoryJson(
                    QByteArrayLiteral("{\"schemaVersion\":1,\"components\":{}}"), &error).isEmpty());
        QVERIFY(!error.isEmpty());
        QVERIFY(ToolkitController::parseInventoryJson(QByteArray(1024 * 1024 + 1, 'x'), &error).isEmpty());
        QVERIFY(error.contains(QStringLiteral("1 MiB")));
    }

    void refreshesInventoryThroughExactLauncherCommand()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json) printf '%s\\n' '{\"schemaVersion\":1,\"source\":\"fake\",\"components\":[]}' ;;\n"
            "  *) exit 90 ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_COMPARE_WITH_TIMEOUT(controller.inventory().value(QStringLiteral("source")).toString(),
                                  QStringLiteral("fake"), 3000);
        QVERIFY(controller.available());
        QCOMPARE(controller.toolkitPath(), QFileInfo(directory.path()).canonicalFilePath());
        QVERIFY(controller.error().isEmpty());
    }

    void blocksActionsWhileInventoryIsRefreshing()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json) sleep 1; printf '%s\\n' '{\"schemaVersion\":1,\"components\":[]}' ;;\n"
            "  action) touch \"$(dirname \"$0\")/unexpected\" ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QVERIFY(controller.refreshing());
        QVERIFY(!controller.start(QStringLiteral("power-install")));
        QVERIFY(controller.error().contains(QStringLiteral("still being refreshed")));
        QVERIFY(!QFileInfo::exists(directory.filePath(QStringLiteral("unexpected"))));
        QTRY_VERIFY_WITH_TIMEOUT(!controller.refreshing(), 3000);
    }

    void failedRefreshInvalidatesInventoryAndBlocksActions()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json)\n"
            "    [[ ! -f \"$(dirname \"$0\")/fail\" ]] || exit 92\n"
            "    printf '%s\\n' '{\"schemaVersion\":1,\"components\":[{\"id\":\"power\",\"label\":\"Power\",\"state\":\"installed\"}]}'\n"
            "    ;;\n"
            "  action) touch \"$(dirname \"$0\")/unexpected\" ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_COMPARE_WITH_TIMEOUT(
            controller.inventory().value(QStringLiteral("components")).toList().size(), 1, 3000);
        QFile fail(directory.filePath(QStringLiteral("fail")));
        QVERIFY(fail.open(QIODevice::WriteOnly));
        fail.close();

        controller.refreshInventory();
        QVERIFY(controller.inventory().isEmpty());
        QTRY_VERIFY_WITH_TIMEOUT(!controller.refreshing(), 3000);
        QVERIFY(!controller.error().isEmpty());
        QVERIFY(!controller.start(QStringLiteral("power-install")));
        QVERIFY(controller.error().contains(QStringLiteral("inventory is unavailable")));
        QVERIFY(!QFileInfo::exists(directory.filePath(QStringLiteral("unexpected"))));
    }

    void refreshesInventoryAfterOperationFinishes()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json)\n"
            "    state=not-installed\n"
            "    [[ -f \"$(dirname \"$0\")/installed\" ]] && state=installed\n"
            "    printf '{\"schemaVersion\":1,\"components\":[{\"id\":\"power\",\"label\":\"Power\",\"state\":\"%s\"}]}\\n' \"$state\"\n"
            "    ;;\n"
            "  action)\n"
            "    [[ $2 == power-install ]] || exit 91\n"
            "    touch \"$(dirname \"$0\")/installed\"\n"
            "    ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_COMPARE_WITH_TIMEOUT(
            controller.inventory().value(QStringLiteral("components")).toList().size(), 1, 3000);
        QCOMPARE(controller.inventory().value(QStringLiteral("components")).toList().constFirst()
                     .toMap().value(QStringLiteral("state")).toString(),
                 QStringLiteral("not-installed"));
        QVERIFY(controller.start(QStringLiteral("power-install")));
        QTRY_COMPARE_WITH_TIMEOUT(controller.resultStatus(), QStringLiteral("succeeded"), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(
            controller.inventory().value(QStringLiteral("components")).toList().constFirst()
                .toMap().value(QStringLiteral("state")).toString(),
            QStringLiteral("installed"), 3000);
        QVERIFY(!controller.refreshing());
    }

    void reportsStagedSwapRemovalAsRebootRequired()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json) printf '%s\\n' '{\"schemaVersion\":1,\"components\":[]}' ;;\n"
            "  action) [[ $2 == swap-remove ]] || exit 91; exit 75 ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(!controller.refreshing(), 3000);
        QVERIFY(controller.start(QStringLiteral("swap-remove")));
        QTRY_COMPARE_WITH_TIMEOUT(controller.resultStatus(), QStringLiteral("reboot-required"), 3000);
        QCOMPARE(controller.exitCode(), 75);
    }

    void reportsAutoBaseInstallationCheckpointAsRebootRequired()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            "  inventory-json) printf '%s\\n' '{\"schemaVersion\":1,\"components\":[]}' ;;\n"
            "  action) [[ $2 == auto-base-installation ]] || exit 91; printf '%s\\n' '[bc250-toolkit] CHECKPOINT: Reboot to resume.' ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(!controller.refreshing(), 3000);
        QVERIFY(controller.start(QStringLiteral("auto-base-installation")));
        QTRY_COMPARE_WITH_TIMEOUT(controller.resultStatus(), QStringLiteral("reboot-required"), 3000);
        QCOMPARE(controller.exitCode(), 0);
    }

    void mockModeNeverExecutesLauncher()
    {
        QTemporaryDir directory;
        const QString touched = directory.filePath(QStringLiteral("executed"));
        writeLauncher(directory.path(), QByteArrayLiteral(
            "touch \"$(dirname \"$0\")/executed\"\n"
            "printf '%s\\n' '{}'\n"));

        ToolkitController controller(true, directory.path());
        QVERIFY(controller.available());
        QVERIFY(controller.inventory().value(QStringLiteral("mock")).toBool());
        QStringList componentIds;
        for (const QVariant &component : controller.inventory().value(QStringLiteral("components")).toList())
            componentIds.append(component.toMap().value(QStringLiteral("id")).toString());
        QCOMPARE(componentIds,
                 QStringList({QStringLiteral("trainer"), QStringLiteral("desktop"),
                              QStringLiteral("decky"), QStringLiteral("coolercontrol"),
                              QStringLiteral("cec"), QStringLiteral("ac3"),
                              QStringLiteral("power"), QStringLiteral("ram"),
                              QStringLiteral("swap"), QStringLiteral("compute"),
                              QStringLiteral("proton"), QStringLiteral("mesh"),
                              QStringLiteral("audio"), QStringLiteral("fan"),
                              QStringLiteral("aic"), QStringLiteral("storage")}));
        QVERIFY(controller.start(QStringLiteral("power-install")));
        QTRY_VERIFY_WITH_TIMEOUT(!controller.running(), 1000);
        QCOMPARE(controller.resultStatus(), QStringLiteral("succeeded"));
        QVERIFY(!QFileInfo::exists(touched));
    }

    void stripsAnsiControlsAndNormalizesOutput()
    {
        const QByteArray output = QByteArrayLiteral("\033[31mred\033[0m\r\nnext\rstep\x01")
            + QString::fromUtf8(" caf\u00e9").toUtf8()
            + ToolkitController::authenticationPromptMarker().toLatin1();
        QCOMPARE(ToolkitController::sanitizedOutput(output),
                 QString::fromUtf8("red\nnext\nstep caf\u00e9"));
    }

    void rejectsUnknownOperationWithoutExecutingIt()
    {
        QTemporaryDir directory;
        writeLauncher(directory.path(), QByteArrayLiteral(
            "if [[ $1 == inventory-json ]]; then printf '%s\\n' '{\"schemaVersion\":1,\"components\":[]}'; else touch unexpected; fi\n"));
        ToolkitController controller(false, directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(controller.available() && !controller.refreshing()
                                     && controller.error().isEmpty(), 3000);

        QVERIFY(!controller.start(QStringLiteral("unknown; touch injected")));
        QCOMPARE(controller.resultStatus(), QStringLiteral("error"));
        QVERIFY(!QFileInfo::exists(directory.filePath(QStringLiteral("unexpected"))));
    }

    void streamsUtf8DetectsAuthenticationAndCancelsProcessGroup()
    {
#ifndef Q_OS_UNIX
        QSKIP("PTY operations require Unix");
#else
        QTemporaryDir directory;
        writeLauncher(directory.path(), QByteArrayLiteral(
            "case \"$1\" in\n"
            " inventory-json) printf '%s\\n' '{\"schemaVersion\":1,\"ready\":true,\"components\":[]}' ;;\n"
             " action)\n"
             "   [[ $2 == power-install ]] || exit 91\n"
            "   printf '\033[32mstart\033[0m\r\n'\n"
            "   printf '\342\230\203'\n"
            "   printf '%s' \"$SUDO_PROMPT\"\n"
            "   trap 'exit 0' TERM INT\n"
            "   while :; do sleep 1; done\n"
            "   ;;\n"
            "esac\n"));

        ToolkitController controller(false, directory.path());
        QTRY_VERIFY_WITH_TIMEOUT(controller.inventory().value(QStringLiteral("ready")).toBool(), 3000);
        QSignalSpy authenticationSpy(&controller, &ToolkitController::authenticationRequested);
        QSignalSpy finishedSpy(&controller, &ToolkitController::operationFinished);
        QVERIFY(controller.start(QStringLiteral("power-install")));
        QTRY_VERIFY_WITH_TIMEOUT(controller.outputText().contains(QString::fromUtf8("start\n\u2603")), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(authenticationSpy.size(), 1, 3000);
        QVERIFY(controller.authenticationPending());
        QVERIFY(!controller.outputText().contains(ToolkitController::authenticationPromptMarker()));
        QVERIFY(controller.cancel());
        QVERIFY(controller.cancelPending());
        QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.size(), 1, 5000);
        QVERIFY(!controller.running());
        QCOMPARE(controller.resultStatus(), QStringLiteral("cancelled"));
#endif
    }

    void rejectsSymlinkLauncher()
    {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString target = directory.filePath(QStringLiteral("real.sh"));
        QFile file(target);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("printf '%s\\n' '{}'\n");
        file.close();
        QVERIFY(QFile::link(target, directory.filePath(QStringLiteral("bc250-toolkit.sh"))));

        ToolkitController controller(false, directory.path());
        QVERIFY(!controller.available());
        QVERIFY(!controller.error().isEmpty());
    }
};

QTEST_GUILESS_MAIN(ToolkitControllerTest)
#include "tst_ToolkitController.moc"
