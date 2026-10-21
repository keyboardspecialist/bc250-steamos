#pragma once

#include <QDBusConnection>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

class QDBusInterface;
class QDBusPendingCallWatcher;
class QDBusServiceWatcher;

class Bc250Bridge final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool serviceAvailable READ serviceAvailable NOTIFY serviceAvailableChanged)
    Q_PROPERTY(bool mockMode READ mockMode CONSTANT)
    Q_PROPERTY(bool visible READ visible WRITE setVisible NOTIFY visibleChanged)
    Q_PROPERTY(bool statusPageActive READ statusPageActive WRITE setStatusPageActive NOTIFY statusPageActiveChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString busyLabel READ busyLabel NOTIFY busyChanged)
    Q_PROPERTY(QString operationId READ operationId NOTIFY operationChanged)
    Q_PROPERTY(bool operationCancellable READ operationCancellable NOTIFY operationChanged)
    Q_PROPERTY(QVariantMap operation READ operation NOTIFY operationChanged)
    Q_PROPERTY(QVariantMap snapshot READ snapshot NOTIFY snapshotChanged)
    Q_PROPERTY(QVariantMap telemetry READ telemetry NOTIFY telemetryChanged)
    Q_PROPERTY(QVariantList telemetryHistory READ telemetryHistory NOTIFY telemetryChanged)
    Q_PROPERTY(QVariantMap cpuUnlockStatus READ cpuUnlockStatus NOTIFY cpuUnlockStatusChanged)
    Q_PROPERTY(QVariantMap meshStatus READ meshStatus NOTIFY meshStatusChanged)
    Q_PROPERTY(QVariantMap fsr4Inventory READ fsr4Inventory NOTIFY fsr4InventoryChanged)
    Q_PROPERTY(QVariantMap cliCatalog READ cliCatalog NOTIFY cliCatalogChanged)
    Q_PROPERTY(QVariantMap capabilities READ capabilities NOTIFY capabilitiesChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString notice READ notice NOTIFY noticeChanged)

public:
    explicit Bc250Bridge(bool mockMode = false, QObject *parent = nullptr);
    ~Bc250Bridge() override;

    bool serviceAvailable() const { return m_serviceAvailable; }
    bool mockMode() const { return m_mockMode; }
    bool visible() const { return m_visible; }
    bool statusPageActive() const { return m_statusPageActive; }
    bool loading() const { return m_loading; }
    bool busy() const { return m_busy; }
    QString busyLabel() const { return m_busyLabel; }
    QString operationId() const { return m_operationId; }
    bool operationCancellable() const { return m_operationCancellable; }
    QVariantMap operation() const { return m_operation; }
    QVariantMap snapshot() const { return m_snapshot; }
    QVariantMap telemetry() const { return m_telemetry; }
    QVariantList telemetryHistory() const { return m_telemetryHistory; }
    QVariantMap cpuUnlockStatus() const { return m_cpuUnlockStatus; }
    QVariantMap meshStatus() const { return m_meshStatus; }
    QVariantMap fsr4Inventory() const { return m_fsr4Inventory; }
    QVariantMap cliCatalog() const { return m_cliCatalog; }
    QVariantMap capabilities() const { return m_capabilities; }
    QString error() const { return m_error; }
    QString notice() const { return m_notice; }

    void setVisible(bool visible);
    void setStatusPageActive(bool active);

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void sampleTelemetry();
    Q_INVOKABLE void setCuWgp(int se, int sh, int wgp, bool enabled);
    Q_INVOKABLE void setGpuFrequency(const QString &mode, int minimum, int maximum);
    Q_INVOKABLE void setLoadTarget(const QString &preset);
    Q_INVOKABLE void setCustomLoadTarget(int minimum, int maximum);
    Q_INVOKABLE void setTemperatureTarget(int target);
    Q_INVOKABLE void setRamp(int milliseconds);
    Q_INVOKABLE void resetGpuRamp();
    Q_INVOKABLE void gpuVoltageAction(const QString &action, int frequency, int voltage, int newFrequency);
    Q_INVOKABLE void refreshFsr4();
    Q_INVOKABLE void setFsr4Dll(const QString &targetId, bool enabled);
    Q_INVOKABLE void prepareHelixsr();
    Q_INVOKABLE void installHelixsr(const QString &targetId);
    Q_INVOKABLE void uninstallHelixsr(const QString &targetId);
    Q_INVOKABLE void installOptiscaler(const QString &candidateId, const QString &proxy);
    Q_INVOKABLE void uninstallOptiscaler(const QString &candidateId);
    Q_INVOKABLE void cecAction(const QString &action);
    Q_INVOKABLE void setCecToggle(const QString &key, bool enabled);
    Q_INVOKABLE void setCecName(const QString &name);
    Q_INVOKABLE void openCliSection(const QString &section);
    Q_INVOKABLE void cpuOcAction(const QString &action, int frequency, int voltage, int temperature);
    Q_INVOKABLE void setCpuMitigations(bool enabled);
    Q_INVOKABLE void setCpuSmtDisabled(bool disabled);
    Q_INVOKABLE void cpuUnlockAction(const QString &action);
    Q_INVOKABLE void setUmaSize(int umaMiB);
    Q_INVOKABLE void setTtmPages(int pages);
    Q_INVOKABLE void removeTtmOverride();
    Q_INVOKABLE void setHdmiSurround(bool enabled);
    Q_INVOKABLE void cancelOperation();
    Q_INVOKABLE void clearMessage();

    static QVariantMap parseJsonObject(const QByteArray &json, QString *error = nullptr);
    static QString sanitizeError(const QString &message);
    static bool isValidOperationId(const QString &operationId);

signals:
    void serviceAvailableChanged();
    void visibleChanged();
    void statusPageActiveChanged();
    void loadingChanged();
    void busyChanged();
    void operationChanged();
    void snapshotChanged();
    void telemetryChanged();
    void cpuUnlockStatusChanged();
    void meshStatusChanged();
    void fsr4InventoryChanged();
    void cliCatalogChanged();
    void capabilitiesChanged();
    void errorChanged();
    void noticeChanged();
    void operationFinished(bool success, const QString &message);

private:
    enum class JsonRequest { Snapshot, Telemetry, CpuUnlock, Mesh, Fsr4, CliCatalog, Operation };

    void setServiceAvailable(bool available);
    void rebuildServiceInterface();
    void updateTelemetryPolling();
    void requestJson(JsonRequest request, const QString &method, const QVariantList &arguments = {});
    void handleJsonReply(JsonRequest request, QDBusPendingCallWatcher *watcher);
    void invalidateTelemetry(const QString &message);
    void startMutation(const QString &method, const QVariantList &arguments, const QString &label,
                       bool cancellable = true);
    void handleMutationReply(QDBusPendingCallWatcher *watcher);
    void pollOperation();
    void completeOperation(bool success, const QString &message);
    void fail(const QString &message, bool finishOperation = false);
    void setError(const QString &message);
    void setNotice(const QString &message);
    void setLoading(bool loading);
    void makeMockSnapshot();
    void startMockMutation(const QString &method, const QVariantList &arguments,
                           const QString &label, bool cancellable);
    void applyMockMutation();
    bool ensureReady();
    bool reject(const QString &message);
    bool discoveredId(const QString &id, bool candidate) const;
    void gameMutation(const QString &method, const QString &id, bool candidate = false,
                      const QString &proxy = QString());

    const bool m_mockMode;
    QDBusConnection m_bus;
    QDBusInterface *m_interface = nullptr;
    QDBusServiceWatcher *m_serviceWatcher = nullptr;
    QTimer m_snapshotTimer;
    QTimer m_telemetryTimer;
    QTimer m_operationTimer;
    QTimer m_noticeTimer;
    QTimer m_mockFinishTimer;

    bool m_serviceAvailable = false;
    bool m_visible = true;
    bool m_statusPageActive = false;
    bool m_loading = true;
    bool m_busy = false;
    bool m_snapshotPending = false;
    bool m_snapshotAgain = false;
    bool m_telemetryPending = false;
    bool m_cpuUnlockPending = false;
    bool m_meshPending = false;
    bool m_fsr4Pending = false;
    bool m_cliCatalogPending = false;
    bool m_operationPending = false;
    bool m_operationCancellable = false;
    bool m_preserveErrorOnRefresh = false;
    bool m_mockSnapshotInitialized = false;
    int m_operationPollFailures = 0;
    QString m_busyLabel;
    QString m_operationId;
    QString m_mockMethod;
    QVariantList m_mockArguments;
    QVariantMap m_operation;
    QVariantMap m_snapshot;
    QVariantMap m_telemetry;
    QVariantList m_telemetryHistory;
    QVariantMap m_cpuUnlockStatus;
    QVariantMap m_meshStatus;
    QVariantMap m_fsr4Inventory;
    QVariantMap m_cliCatalog;
    QVariantMap m_capabilities;
    QString m_error;
    QString m_notice;
};
