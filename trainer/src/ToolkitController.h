#pragma once

#include <QByteArray>
#include <QObject>
#include <QStringConverter>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

class QProcess;
class QSocketNotifier;

class ToolkitController final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(QString toolkitPath READ toolkitPath NOTIFY toolkitPathChanged)
    Q_PROPERTY(QVariantMap inventory READ inventory NOTIFY inventoryChanged)
    Q_PROPERTY(QVariantList operations READ operations CONSTANT)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY refreshingChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString activeOperationId READ activeOperationId NOTIFY activeOperationChanged)
    Q_PROPERTY(QString activeOperationTitle READ activeOperationTitle NOTIFY activeOperationChanged)
    Q_PROPERTY(bool cancellable READ cancellable NOTIFY activeOperationChanged)
    Q_PROPERTY(bool cancelPending READ cancelPending NOTIFY cancelPendingChanged)
    Q_PROPERTY(bool authenticationPending READ authenticationPending NOTIFY authenticationPendingChanged)
    Q_PROPERTY(QString outputText READ outputText NOTIFY outputTextChanged)
    Q_PROPERTY(int exitCode READ exitCode NOTIFY resultChanged)
    Q_PROPERTY(QString resultStatus READ resultStatus NOTIFY resultChanged)
    Q_PROPERTY(QVariantMap result READ result NOTIFY resultChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    explicit ToolkitController(bool mockMode = false,
                               const QString &toolkitDirectoryOverride = QString(),
                               QObject *parent = nullptr);
    ~ToolkitController() override;

    bool available() const { return m_available; }
    QString toolkitPath() const { return m_toolkitPath; }
    QVariantMap inventory() const { return m_inventory; }
    QVariantList operations() const;
    bool refreshing() const { return m_refreshing; }
    bool running() const { return m_running; }
    QString activeOperationId() const { return m_activeOperationId; }
    QString activeOperationTitle() const { return m_activeOperationTitle; }
    bool cancellable() const { return m_cancellable; }
    bool cancelPending() const { return m_cancelPending; }
    bool authenticationPending() const { return m_authenticationPending; }
    QString outputText() const { return m_outputText; }
    int exitCode() const { return m_exitCode; }
    QString resultStatus() const { return m_resultStatus; }
    QVariantMap result() const;
    QString error() const { return m_error; }

    Q_INVOKABLE void refreshInventory();
    Q_INVOKABLE bool start(const QString &operationId);
    Q_INVOKABLE bool cancel();
    Q_INVOKABLE bool submitPassword(const QString &password);
    Q_INVOKABLE bool submitInput(const QString &input);
    Q_INVOKABLE void clearOutput();
    Q_INVOKABLE void clearError();

    static QVariantMap operationMetadata(const QString &operationId);
    static QVariantMap parseInventoryJson(const QByteArray &json, QString *error = nullptr);
    static QString sanitizedOutput(const QByteArray &output);
    static QString authenticationPromptMarker();

signals:
    void availableChanged();
    void toolkitPathChanged();
    void inventoryChanged();
    void refreshingChanged();
    void runningChanged();
    void activeOperationChanged();
    void cancelPendingChanged();
    void authenticationPendingChanged();
    void outputTextChanged();
    void resultChanged();
    void errorChanged();
    void authenticationRequested();
    void operationFinished(const QString &operationId, const QString &status, int exitCode);

private:
    enum class EscapeState { Normal, Escape, Csi, Osc, OscEscape };

    QString requestedToolkitPath() const;
    bool validateToolkit(QString *canonicalDirectory, QString *error) const;
    void setAvailable(bool available);
    void setToolkitPath(const QString &path);
    void setRefreshing(bool refreshing);
    void setError(const QString &error);
    void beginOperation(const QVariantMap &metadata);
    void finishOperation(int exitCode, const QString &status, const QString &error = QString());
    void pollChild();
    void drainPty();
    void flushInput();
    void consumeBytes(const QByteArray &bytes);
    void consumeDecodedText(const QString &text);
    void appendNormalized(const QString &text);
    void appendOutput(const QString &text);
    void flushOutputDecoder();
    void closePty();
    void stopChildImmediately();
    bool queueInput(const QString &input, bool appendNewline);
    static QByteArray stripTerminalControls(const QByteArray &input, EscapeState *state);
    static QString normalizeCarriageReturns(const QString &text);
    static QString cleanError(const QString &error);
    QVariantMap mockInventory() const;

    const bool m_mockMode;
    const QString m_toolkitDirectoryOverride;
    bool m_available = false;
    bool m_refreshing = false;
    bool m_running = false;
    bool m_cancellable = false;
    bool m_cancelPending = false;
    bool m_authenticationPending = false;
    bool m_pendingCarriageReturn = false;
    int m_exitCode = -1;
    int m_ptyFd = -1;
    qint64 m_childPid = -1;
    qint64 m_childProcessGroup = -1;
    EscapeState m_escapeState = EscapeState::Normal;
    QStringDecoder m_utf8Decoder{QStringDecoder::Utf8};
    QString m_toolkitPath;
    QString m_activeOperationId;
    QString m_activeOperationTitle;
    QString m_outputText;
    QString m_markerBuffer;
    QString m_resultStatus = QStringLiteral("idle");
    QString m_error;
    QByteArray m_pendingInput;
    QByteArray m_inventoryStdout;
    QByteArray m_inventoryStderr;
    QString m_inventoryFailure;
    QVariantMap m_inventory;
    QProcess *m_inventoryProcess = nullptr;
    QSocketNotifier *m_readNotifier = nullptr;
    QSocketNotifier *m_writeNotifier = nullptr;
    QTimer m_childPollTimer;
    QTimer m_cancelTimer;
    QTimer m_mockTimer;
};
