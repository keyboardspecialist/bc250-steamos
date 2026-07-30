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
    }

    void mockUnlockSchemaMatchesService()
    {
        Bc250Bridge bridge(true);
        const QVariantMap unlock = bridge.cpuUnlockStatus();
        QCOMPARE(unlock.value(QStringLiteral("schemaVersion")).toInt(), 1);
        QCOMPARE(unlock.value(QStringLiteral("guard")).toMap().value(QStringLiteral("state")).toString(),
                 QStringLiteral("clear"));
        QVERIFY(unlock.value(QStringLiteral("actions")).toMap()
                    .value(QStringLiteral("test")).toMap()
                    .value(QStringLiteral("available")).toBool());
        QCOMPARE(unlock.value(QStringLiteral("ccxGroups")).toList().size(), 2);
    }
};

QTEST_GUILESS_MAIN(Bc250BridgeTest)
#include "tst_Bc250Bridge.moc"
