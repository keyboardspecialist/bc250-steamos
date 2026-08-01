#include "Bc250Bridge.h"
#include "MediaController.h"
#include "ToolkitController.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QTimer>

int main(int argc, char *argv[])
{
    QGuiApplication::setOrganizationName(QStringLiteral("keyboardspecialist"));
    QGuiApplication::setOrganizationDomain(QStringLiteral("io.github.keyboardspecialist"));
    QGuiApplication::setApplicationName(QStringLiteral("BC250 Trainer"));
    QGuiApplication::setApplicationVersion(QStringLiteral(BC250_TRAINER_VERSION));

    QGuiApplication application(argc, argv);
    QQuickStyle::setStyle(QStringLiteral("Fusion"));

    const QStringList arguments = application.arguments();
    const bool mockMode = arguments.contains(QStringLiteral("--mock"))
        || qEnvironmentVariableIntValue("BC250_TRAINER_MOCK") != 0;
    const bool smokeTest = arguments.contains(QStringLiteral("--smoke-test"));

    Bc250Bridge bridge(mockMode);
    ToolkitController toolkitController(mockMode);
    MediaController mediaController(nullptr, !smokeTest, QStringLiteral("bc250-trainer"),
                                    !smokeTest);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("bridge"), &bridge);
    engine.rootContext()->setContextProperty(QStringLiteral("toolkitController"),
                                              &toolkitController);
    engine.rootContext()->setContextProperty(QStringLiteral("mediaController"), &mediaController);
    engine.rootContext()->setContextProperty(QStringLiteral("applicationVersion"),
                                              application.applicationVersion());
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &application, [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));

    if (smokeTest && !engine.rootObjects().isEmpty()) {
        engine.rootObjects().constFirst()->setProperty("currentPage", 0);
        QTimer::singleShot(1200, &application, &QCoreApplication::quit);
    }

    return application.exec();
}
