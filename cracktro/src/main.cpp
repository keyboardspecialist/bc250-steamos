#include "Bc250Bridge.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QTimer>

int main(int argc, char *argv[])
{
    QGuiApplication::setOrganizationName(QStringLiteral("keyboardspecialist"));
    QGuiApplication::setOrganizationDomain(QStringLiteral("io.github.keyboardspecialist"));
    QGuiApplication::setApplicationName(QStringLiteral("BC-250 Cracktro"));
    QGuiApplication::setApplicationVersion(QStringLiteral(BC250_CRACKTRO_VERSION));

    QGuiApplication application(argc, argv);
    QQuickStyle::setStyle(QStringLiteral("Fusion"));

    const QStringList arguments = application.arguments();
    const bool mockMode = arguments.contains(QStringLiteral("--mock"))
        || qEnvironmentVariableIntValue("BC250_CRACKTRO_MOCK") != 0;
    const bool smokeTest = arguments.contains(QStringLiteral("--smoke-test"));

    Bc250Bridge bridge(mockMode);
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("bridge"), &bridge);
    engine.rootContext()->setContextProperty(QStringLiteral("applicationVersion"),
                                              application.applicationVersion());
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &application, [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);
    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));

    if (smokeTest)
        QTimer::singleShot(1200, &application, &QCoreApplication::quit);

    return application.exec();
}
