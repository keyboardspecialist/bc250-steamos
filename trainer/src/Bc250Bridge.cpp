#include "Bc250Bridge.h"

#include <QDBusConnectionInterface>
#include <QDBusError>
#include <QDBusInterface>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusReply>
#include <QDBusServiceWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QUuid>

namespace {
constexpr auto Service = "io.github.keyboardspecialist.BC250Control1";
constexpr auto ObjectPath = "/io/github/keyboardspecialist/BC250Control1";
constexpr auto Interface = "io.github.keyboardspecialist.BC250Control1";

QString replyError(const QDBusError &error)
{
    return Bc250Bridge::sanitizeError(error.message().isEmpty() ? error.name() : error.message());
}
}

Bc250Bridge::Bc250Bridge(bool mockMode, QObject *parent)
    : QObject(parent)
    , m_mockMode(mockMode)
    , m_bus(QDBusConnection::systemBus())
{
    m_snapshotTimer.setInterval(10000);
    m_telemetryTimer.setInterval(1000);
    m_operationTimer.setInterval(750);
    m_noticeTimer.setInterval(7000);
    m_noticeTimer.setSingleShot(true);
    m_mockFinishTimer.setInterval(900);
    m_mockFinishTimer.setSingleShot(true);

    connect(&m_snapshotTimer, &QTimer::timeout, this, &Bc250Bridge::refresh);
    connect(&m_telemetryTimer, &QTimer::timeout, this, &Bc250Bridge::sampleTelemetry);
    connect(&m_operationTimer, &QTimer::timeout, this, &Bc250Bridge::pollOperation);
    connect(&m_noticeTimer, &QTimer::timeout, this, [this] { setNotice({}); });
    connect(&m_mockFinishTimer, &QTimer::timeout, this, [this] {
        const QString message = m_busyLabel + QStringLiteral(" completed (mock; no hardware call). ");
        m_operation.insert(QStringLiteral("status"), QStringLiteral("succeeded"));
        m_operation.insert(QStringLiteral("cancellable"), false);
        emit operationChanged();
        completeOperation(true, message.trimmed());
    });

    if (m_mockMode) {
        setServiceAvailable(true);
        makeMockSnapshot();
        setLoading(false);
        setNotice(QStringLiteral("MOCK MODE: all hardware mutations are simulated."));
        m_snapshotTimer.start();
        m_telemetryTimer.start();
        QTimer::singleShot(0, this, &Bc250Bridge::sampleTelemetry);
        return;
    }

    m_interface = new QDBusInterface(QString::fromLatin1(Service), QString::fromLatin1(ObjectPath),
                                      QString::fromLatin1(Interface), m_bus, this);
    m_serviceWatcher = new QDBusServiceWatcher(QString::fromLatin1(Service), m_bus,
        QDBusServiceWatcher::WatchForRegistration | QDBusServiceWatcher::WatchForUnregistration, this);
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        setServiceAvailable(true);
        refresh();
    });
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceUnregistered, this, [this] {
        setServiceAvailable(false);
        setLoading(false);
        if (m_busy)
            fail(QStringLiteral("The BC-250 service disappeared while an operation was active."), true);
        else
            setError(QStringLiteral("The BC-250 system service is unavailable."));
    });

    bool registered = false;
    if (m_bus.isConnected() && m_bus.interface()) {
        const QDBusReply<bool> registration =
            m_bus.interface()->isServiceRegistered(QString::fromLatin1(Service));
        registered = registration.isValid() && registration.value();
    }
    setServiceAvailable(registered);
    m_snapshotTimer.start();
    m_telemetryTimer.start();
    if (registered)
        QTimer::singleShot(0, this, &Bc250Bridge::refresh);
    else {
        setLoading(false);
        setError(m_bus.isConnected() ? QStringLiteral("The BC-250 system service is unavailable.")
                                     : QStringLiteral("The system D-Bus is unavailable."));
    }
}

Bc250Bridge::~Bc250Bridge() = default;

void Bc250Bridge::setVisible(bool visible)
{
    if (m_visible == visible)
        return;
    m_visible = visible;
    emit visibleChanged();
    if (visible) {
        m_snapshotTimer.start();
        refresh();
    } else {
        m_snapshotTimer.stop();
    }
}

void Bc250Bridge::setStatusPageActive(bool active)
{
    if (m_statusPageActive == active)
        return;
    m_statusPageActive = active;
    emit statusPageActiveChanged();
    if (active && m_visible)
        sampleTelemetry();
}

void Bc250Bridge::refresh()
{
    if (m_busy)
        return;
    if (m_mockMode) {
        makeMockSnapshot();
        setLoading(false);
        return;
    }
    if (!m_serviceAvailable) {
        setLoading(false);
        return;
    }
    if (m_snapshotPending) {
        m_snapshotAgain = true;
        return;
    }
    setLoading(m_snapshot.isEmpty());
    requestJson(JsonRequest::Snapshot, QStringLiteral("GetSnapshot"));
    if (!m_cpuUnlockPending)
        requestJson(JsonRequest::CpuUnlock, QStringLiteral("GetCpuUnlockStatus"));
    if (!m_meshPending)
        requestJson(JsonRequest::Mesh, QStringLiteral("GetMeshStatus"));
}

void Bc250Bridge::sampleTelemetry()
{
    if (!m_visible || !m_statusPageActive || m_busy || m_telemetryPending)
        return;
    if (m_mockMode) {
        const int phase = m_telemetryHistory.size() % 7;
        m_telemetry = {
            {QStringLiteral("cpuClock"), 3450 + phase * 37},
            {QStringLiteral("gpuClock"), 980 + phase * 29},
            {QStringLiteral("cpuTemp"), 51 + phase},
            {QStringLiteral("gpuTemp"), 55 + phase / 2}
        };
        m_telemetryHistory.append(m_telemetry);
        while (m_telemetryHistory.size() > 36)
            m_telemetryHistory.removeFirst();
        emit telemetryChanged();
        return;
    }
    if (m_serviceAvailable)
        requestJson(JsonRequest::Telemetry, QStringLiteral("GetTelemetry"));
}

void Bc250Bridge::requestJson(JsonRequest request, const QString &method, const QVariantList &arguments)
{
    if (!m_interface || !m_serviceAvailable)
        return;
    switch (request) {
    case JsonRequest::Snapshot: m_snapshotPending = true; break;
    case JsonRequest::Telemetry: m_telemetryPending = true; break;
    case JsonRequest::CpuUnlock: m_cpuUnlockPending = true; break;
    case JsonRequest::Mesh: m_meshPending = true; break;
    case JsonRequest::Operation: m_operationPending = true; break;
    }
    auto *watcher = new QDBusPendingCallWatcher(m_interface->asyncCallWithArgumentList(method, arguments), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, request](QDBusPendingCallWatcher *completed) { handleJsonReply(request, completed); });
}

void Bc250Bridge::handleJsonReply(JsonRequest request, QDBusPendingCallWatcher *watcher)
{
    QDBusPendingReply<QString> reply = *watcher;
    watcher->deleteLater();
    switch (request) {
    case JsonRequest::Snapshot: m_snapshotPending = false; break;
    case JsonRequest::Telemetry: m_telemetryPending = false; break;
    case JsonRequest::CpuUnlock: m_cpuUnlockPending = false; break;
    case JsonRequest::Mesh: m_meshPending = false; break;
    case JsonRequest::Operation: m_operationPending = false; break;
    }

    if (reply.isError()) {
        const QString message = replyError(reply.error());
        if (request == JsonRequest::Operation) {
            if (++m_operationPollFailures >= 8
                || reply.error().name().contains(QStringLiteral("UnknownObject")))
                fail(QStringLiteral("Operation status is no longer available. Refresh before retrying."), true);
            else
                setError(message + QStringLiteral(" Retrying operation status."));
        } else if (request == JsonRequest::CpuUnlock
                   && reply.error().name().contains(QStringLiteral("UnknownMethod"))) {
            m_cpuUnlockStatus = {
                {QStringLiteral("available"), false},
                {QStringLiteral("blockers"), QVariantList{QStringLiteral("service-extension-unavailable")}},
                {QStringLiteral("message"), QStringLiteral("The installed service does not provide CPU core unlock yet.")}
            };
            emit cpuUnlockStatusChanged();
        } else if (request == JsonRequest::Mesh
                   && reply.error().name().contains(QStringLiteral("UnknownMethod"))) {
            m_meshStatus = {
                {QStringLiteral("scriptAvailable"), false},
                {QStringLiteral("runtimeState"), QStringLiteral("not-installed")},
                {QStringLiteral("fsr4State"), QStringLiteral("not-installed")},
                {QStringLiteral("error"), QStringLiteral("The installed service does not provide Mesa / RADV status yet.")}
            };
            emit meshStatusChanged();
        } else if (request != JsonRequest::Telemetry) {
            setError(message);
        }
        setLoading(false);
    } else {
        QString parseError;
        const QVariantMap value = parseJsonObject(reply.value().toUtf8(), &parseError);
        if (!parseError.isEmpty()) {
            if (request == JsonRequest::Operation)
                fail(parseError, true);
            else if (request != JsonRequest::Telemetry)
                setError(parseError);
        } else if (request == JsonRequest::Snapshot) {
            m_snapshot = value;
            emit snapshotChanged();
            setError({});
            setLoading(false);
        } else if (request == JsonRequest::Telemetry) {
            m_telemetry = value;
            m_telemetryHistory.append(value);
            while (m_telemetryHistory.size() > 36)
                m_telemetryHistory.removeFirst();
            emit telemetryChanged();
        } else if (request == JsonRequest::CpuUnlock) {
            m_cpuUnlockStatus = value;
            emit cpuUnlockStatusChanged();
        } else if (request == JsonRequest::Mesh) {
            m_meshStatus = value;
            emit meshStatusChanged();
        } else {
            m_operationPollFailures = 0;
            setError({});
            m_operation = value;
            m_operationCancellable = value.value(QStringLiteral("cancellable"), true).toBool();
            emit operationChanged();
            const QString status = value.value(QStringLiteral("status")).toString();
            if (status == QStringLiteral("succeeded")) {
                QString message = value.value(QStringLiteral("message")).toString();
                const QVariantMap result = value.value(QStringLiteral("result")).toMap();
                if (message.isEmpty())
                    message = result.value(QStringLiteral("message")).toString();
                const QString nextStep = result.value(QStringLiteral("nextStep")).toString();
                QString nextStepMessage;
                if (nextStep == QStringLiteral("warm-reboot"))
                    nextStepMessage = QStringLiteral("Warm reboot required.");
                else if (nextStep == QStringLiteral("full-power-off"))
                    nextStepMessage = QStringLiteral("Full power-off required.");
                if (!nextStepMessage.isEmpty())
                    message += (message.isEmpty() ? QString() : QStringLiteral(" ")) + nextStepMessage;
                if (message.isEmpty())
                    message = value.value(QStringLiteral("method")).toString() + QStringLiteral(" completed.");
                completeOperation(true, message);
            } else if (status == QStringLiteral("failed")) {
                completeOperation(false, value.value(QStringLiteral("error"),
                    QStringLiteral("The hardware operation failed.")).toString());
            } else if (status == QStringLiteral("cancelled")) {
                completeOperation(false, QStringLiteral("Operation cancelled."));
            } else if (status != QStringLiteral("queued") && status != QStringLiteral("running")) {
                fail(QStringLiteral("The service returned an unknown operation state."), true);
            } else if (!value.value(QStringLiteral("label")).toString().isEmpty()) {
                m_busyLabel = value.value(QStringLiteral("label")).toString();
                emit busyChanged();
            }
        }
    }

    if (request == JsonRequest::Snapshot && m_snapshotAgain && !m_busy) {
        m_snapshotAgain = false;
        refresh();
    }
}

bool Bc250Bridge::ensureReady()
{
    if (m_busy)
        return reject(QStringLiteral("Another hardware operation is already active."));
    if (!m_serviceAvailable)
        return reject(QStringLiteral("The BC-250 system service is unavailable."));
    const QVariantMap guard = m_cpuUnlockStatus.value(QStringLiteral("guard")).toMap();
    if (guard.value(QStringLiteral("state")).toString() == QStringLiteral("automatic"))
        return reject(QStringLiteral("Hardware controls are blocked while an automatic guarded reboot is pending."));
    return true;
}

bool Bc250Bridge::reject(const QString &message)
{
    setError(message);
    return false;
}

void Bc250Bridge::setCuWgp(int se, int sh, int wgp, bool enabled)
{
    if (se < 0 || se > 1 || sh < 0 || sh > 1 || wgp < 0 || wgp > 4) {
        reject(QStringLiteral("CU routing coordinates are out of range."));
        return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCuWgp"),
        {QVariant::fromValue<uchar>(se), QVariant::fromValue<uchar>(sh),
         QVariant::fromValue<uchar>(wgp), enabled},
        (enabled ? QStringLiteral("Enabling ") : QStringLiteral("Disabling "))
            + QStringLiteral("CU%1-%2").arg(wgp * 2).arg(wgp * 2 + 1));
}

void Bc250Bridge::setGpuFrequency(const QString &mode, int minimum, int maximum)
{
    if (!QStringList{QStringLiteral("adaptive"), QStringLiteral("range"), QStringLiteral("pin"),
                     QStringLiteral("max")}.contains(mode)) {
        reject(QStringLiteral("Unknown GPU frequency mode.")); return;
    }
    if (mode == QStringLiteral("pin") && (maximum < 300 || maximum > 2230)) {
        reject(QStringLiteral("Pinned frequency must be 300-2230 MHz.")); return;
    }
    if (mode == QStringLiteral("range") && ((minimum != 0 && minimum < 300) || minimum > 2230 || maximum < 300
        || maximum > 2230 || (minimum != 0 && minimum > maximum))) {
        reject(QStringLiteral("GPU frequency range is invalid.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetGpuFrequency"),
        {mode, QVariant::fromValue<uint>(minimum), QVariant::fromValue<uint>(maximum)},
        QStringLiteral("Applying GPU frequency mode"));
}

void Bc250Bridge::setLoadTarget(const QString &preset)
{
    if (preset != QStringLiteral("eager") && preset != QStringLiteral("reset")) {
        reject(QStringLiteral("Unknown load-target preset.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetLoadTarget"), {preset}, QStringLiteral("Applying GPU load target"));
}

void Bc250Bridge::setCustomLoadTarget(int minimum, int maximum)
{
    if (minimum < 1 || maximum > 99 || minimum >= maximum) {
        reject(QStringLiteral("Minimum GPU load must be below maximum load and both must be 1-99%.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCustomLoadTarget"),
        {QVariant::fromValue<uchar>(minimum), QVariant::fromValue<uchar>(maximum)},
        QStringLiteral("Applying custom GPU load target"));
}

void Bc250Bridge::setRamp(int milliseconds)
{
    if (milliseconds < 200 || milliseconds > 5000) {
        reject(QStringLiteral("Ramp time must be 200-5000 ms.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetRamp"), {QVariant::fromValue<uint>(milliseconds)},
                  QStringLiteral("Applying GPU ramp time"));
}

void Bc250Bridge::cpuOcAction(const QString &action, int frequency, int voltage, int temperature)
{
    if (!QStringList{QStringLiteral("detect"), QStringLiteral("apply"), QStringLiteral("enable"),
                     QStringLiteral("off")}.contains(action)) {
        reject(QStringLiteral("Unknown CPU overclock action.")); return;
    }
    if (action == QStringLiteral("detect") && (frequency < 3500 || frequency > 4500
        || voltage < 950 || voltage > 1325 || temperature < 50 || temperature > 100)) {
        reject(QStringLiteral("CPU detection values are outside the service safety bounds.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("CpuOcAction"),
        {action, QVariant::fromValue<uint>(frequency), QVariant::fromValue<uint>(voltage),
         QVariant::fromValue<uint>(temperature)}, QStringLiteral("Running CPU ") + action);
}

void Bc250Bridge::cpuUnlockAction(const QString &action)
{
    if (!QStringList{QStringLiteral("test"), QStringLiteral("enable"), QStringLiteral("efi-enable"),
                     QStringLiteral("off")}.contains(action)) {
        reject(QStringLiteral("Unknown CPU core-unlock action.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("CpuUnlockAction"), {action},
                  QStringLiteral("Running CPU core-unlock ") + action, false);
}

void Bc250Bridge::setCpuMitigations(bool enabled)
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCpuMitigations"), {enabled},
                  enabled ? QStringLiteral("Enabling CPU mitigations")
                          : QStringLiteral("Disabling CPU mitigations"), false);
}

void Bc250Bridge::setUmaSize(int umaMiB)
{
    if (umaMiB < 256 || umaMiB > 12288 || umaMiB % 16 != 0 || umaMiB == 2048) {
        reject(QStringLiteral("UMA size must be 256-12288 MiB, aligned to 16 MiB, and not 2048 MiB."));
        return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetUmaSize"), {QVariant::fromValue<uint>(umaMiB)},
                  QStringLiteral("Writing CMOS UMA split"), false);
}

void Bc250Bridge::setTtmPages(int pages)
{
    if (pages < 65536 || pages > 3145728) {
        reject(QStringLiteral("TTM limit must be 65536-3145728 pages."));
        return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetTtmPages"), {QVariant::fromValue<uint>(pages)},
                  QStringLiteral("Updating TTM boot limit"), false);
}

void Bc250Bridge::removeTtmOverride()
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("RemoveTtmOverride"), {},
                  QStringLiteral("Removing TTM boot limit"), false);
}

void Bc250Bridge::setHdmiSurround(bool enabled)
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetHdmiSurround"), {enabled},
                  enabled ? QStringLiteral("Enabling HDMI surround")
                          : QStringLiteral("Disabling HDMI surround"), false);
}

void Bc250Bridge::startMutation(const QString &method, const QVariantList &arguments,
                                const QString &label, bool cancellable)
{
    setError({});
    setNotice({});
    m_busy = true;
    m_busyLabel = label;
    m_operationCancellable = cancellable;
    m_operationPollFailures = 0;
    emit busyChanged();
    emit operationChanged();
    if (m_mockMode) {
        startMockMutation(label, cancellable);
        return;
    }
    auto *watcher = new QDBusPendingCallWatcher(m_interface->asyncCallWithArgumentList(method, arguments), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, &Bc250Bridge::handleMutationReply);
}

void Bc250Bridge::handleMutationReply(QDBusPendingCallWatcher *watcher)
{
    QDBusPendingReply<QString> reply = *watcher;
    watcher->deleteLater();
    if (reply.isError()) {
        fail(replyError(reply.error()), true);
        return;
    }
    if (!isValidOperationId(reply.value())) {
        fail(QStringLiteral("The service returned an invalid operation ID."), true);
        return;
    }
    m_operationId = reply.value();
    m_operation = {{QStringLiteral("status"), QStringLiteral("queued")},
                   {QStringLiteral("cancellable"), m_operationCancellable}};
    emit operationChanged();
    m_operationTimer.start();
    pollOperation();
}

void Bc250Bridge::pollOperation()
{
    if (!m_busy || !isValidOperationId(m_operationId) || m_operationPending || m_mockMode)
        return;
    requestJson(JsonRequest::Operation, QStringLiteral("GetOperation"), {m_operationId});
}

void Bc250Bridge::cancelOperation()
{
    if (!m_busy || !isValidOperationId(m_operationId))
        return;
    if (!m_operationCancellable) {
        setNotice(QStringLiteral("This critical operation cannot be cancelled safely."));
        return;
    }
    if (m_mockMode) {
        m_mockFinishTimer.stop();
        completeOperation(false, QStringLiteral("Operation cancelled (mock)."));
        return;
    }
    auto *watcher = new QDBusPendingCallWatcher(
        m_interface->asyncCallWithArgumentList(QStringLiteral("CancelOperation"), {m_operationId}), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *completed) {
        QDBusPendingReply<bool> reply = *completed;
        completed->deleteLater();
        if (reply.isError())
            setError(replyError(reply.error()));
        else if (!reply.value())
            setNotice(QStringLiteral("The operation had already finished and could not be cancelled."));
    });
}

void Bc250Bridge::completeOperation(bool success, const QString &message)
{
    m_operationTimer.stop();
    m_operationPending = false;
    m_busy = false;
    m_busyLabel.clear();
    m_operationId.clear();
    m_operationCancellable = false;
    emit busyChanged();
    emit operationChanged();
    if (success) {
        setError({});
        setNotice(sanitizeError(message));
    } else {
        setError(sanitizeError(message));
    }
    emit operationFinished(success, sanitizeError(message));
    refresh();
}

void Bc250Bridge::fail(const QString &message, bool finishOperation)
{
    if (finishOperation) {
        m_operationTimer.stop();
        m_busy = false;
        m_busyLabel.clear();
        m_operationId.clear();
        m_operationCancellable = false;
        emit busyChanged();
        emit operationChanged();
        emit operationFinished(false, sanitizeError(message));
    }
    setError(message);
}

void Bc250Bridge::clearMessage()
{
    setError({});
    setNotice({});
}

void Bc250Bridge::setServiceAvailable(bool available)
{
    if (m_serviceAvailable == available)
        return;
    m_serviceAvailable = available;
    emit serviceAvailableChanged();
}

void Bc250Bridge::setError(const QString &message)
{
    const QString clean = sanitizeError(message);
    if (m_error == clean)
        return;
    m_error = clean;
    emit errorChanged();
}

void Bc250Bridge::setNotice(const QString &message)
{
    const QString clean = sanitizeError(message);
    if (m_notice == clean) {
        if (!clean.isEmpty()) m_noticeTimer.start();
        return;
    }
    m_notice = clean;
    if (clean.isEmpty()) m_noticeTimer.stop(); else m_noticeTimer.start();
    emit noticeChanged();
}

void Bc250Bridge::setLoading(bool loading)
{
    if (m_loading == loading)
        return;
    m_loading = loading;
    emit loadingChanged();
}

QVariantMap Bc250Bridge::parseJsonObject(const QByteArray &json, QString *error)
{
    if (error) error->clear();
    if (json.size() > 1024 * 1024) {
        if (error) *error = QStringLiteral("The service response is too large.");
        return {};
    }
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) *error = QStringLiteral("The service returned invalid JSON: ")
            + sanitizeError(parseError.errorString());
        return {};
    }
    return document.object().toVariantMap();
}

QString Bc250Bridge::sanitizeError(const QString &message)
{
    QString clean = message;
    clean.replace(QRegularExpression(QStringLiteral("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]")), QStringLiteral(" "));
    clean.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    clean = clean.trimmed();
    if (clean.size() > 600)
        clean = clean.left(597) + QStringLiteral("...");
    return clean;
}

bool Bc250Bridge::isValidOperationId(const QString &operationId)
{
    static const QRegularExpression pattern(QStringLiteral("^[0-9a-fA-F]{32}$"));
    return pattern.match(operationId).hasMatch();
}

void Bc250Bridge::makeMockSnapshot()
{
    static const QByteArray json = R"json({
      "schemaVersion":1,
      "toolkit":{"available":true,"privileged":true,"powerAvailable":true,"cpuControlAvailable":true,"ramControlAvailable":true,"audioAvailable":true,"path":"/mock/bc250-steamos","version":"mock-1"},
      "cu":{"available":true,"controllable":true,"liveReason":"","total":24,"maximum":40,"factoryMapAvailable":true,"factoryTotal":24,"savedMasks":[7,7,7,7],"protected":true,"service":{"enabled":"enabled","active":"active"},"rows":[
        {"se":0,"sh":0,"wgps":[true,true,true,false,false],"factoryWgps":[true,true,true,false,false],"cus":6},
        {"se":0,"sh":1,"wgps":[true,true,true,false,false],"factoryWgps":[true,true,true,false,false],"cus":6},
        {"se":1,"sh":0,"wgps":[true,true,true,false,false],"factoryWgps":[true,true,true,false,false],"cus":6},
        {"se":1,"sh":1,"wgps":[true,true,true,false,false],"factoryWgps":[true,true,true,false,false],"cus":6}]},
      "power":{"acpiActive":true,"cStates":3,"cpuGovernor":"schedutil","cpuCurrentMhz":3650,"governor":{"enabled":"enabled","active":"active"},"frequencyRestore":{"enabled":"enabled","active":"exited"},"temperatures":[{"device":"amdgpu","label":"edge","celsius":57}]},
      "gpu":{"available":true,"controllable":true,"dbusReady":true,"mode":"adaptive","requestedMode":"adaptive","minimum":300,"maximum":1500,"liveMinimum":300,"liveMaximum":1500,"activeMhz":1120,"allowedMinimum":300,"allowedMaximum":2230,"climbMs":500,"loadUpper":0.80,"loadLower":0.65,"configuredMax":1500,"persistent":true,"replayApplied":true,"governorService":{"enabled":"enabled","active":"active"},"safePoints":[{"frequency":300,"voltage":700},{"frequency":1500,"voltage":975}]},
      "cpu":{"service":{"enabled":"enabled","active":"active"},"installed":{"values":{"frequency":"4000","voltage":"1275"},"detected":"4000 MHz @ 1275 mV"},"staged":null,"toolAvailable":true,"mitigations":{"schemaVersion":1,"available":true,"state":"enabled","configuredEnabled":true,"bootEnabled":true,"rebootRequired":false,"protected":true}},
      "ram":{"schemaVersion":1,"available":true,"toolState":"verified","toolVersion":"v0.1","umaLastRequestedMiB":512,"ttmState":"configured","ttmConfiguredPages":3014656,"ttmBootPages":3014656,"ttmLivePages":3014656,"rebootRequired":false,"protected":true},
      "audio":{"available":true,"controllable":true,"state":"active","enabled":true,"active":true,"udevState":"installed","wireplumberState":"installed","persistenceState":"installed","activeProfile":"output:hdmi-ac3-surround"}
    })json";
    QString parseError;
    m_snapshot = parseJsonObject(json, &parseError);
    m_meshStatus = {
        {QStringLiteral("scriptAvailable"), true},
        {QStringLiteral("runtimeState"), QStringLiteral("ready")},
        {QStringLiteral("mesaVersion"), QStringLiteral("mesa-26.2.0")},
        {QStringLiteral("kernelReady"), true},
        {QStringLiteral("schedulerConfigured"), true},
        {QStringLiteral("schedulerActive"), true},
        {QStringLiteral("globalEnabled"), true},
        {QStringLiteral("restartRequired"), false},
        {QStringLiteral("fsr4State"), QStringLiteral("ready")},
        {QStringLiteral("fsr4RunnerPath"), QStringLiteral("/home/deck/.local/share/bc250-mesh-shader/fsr4/bc250-fsr4-run")}
    };
    const auto mockCore = [](int core, int ccx) {
        return QVariantMap{{QStringLiteral("packageId"), 0}, {QStringLiteral("coreId"), core},
                           {QStringLiteral("logicalCpus"), QVariantList{core, core + 8}},
                           {QStringLiteral("ccxId"), ccx}};
    };
    QVariantList cores;
    QVariantList firstCcx;
    QVariantList secondCcx;
    for (int core = 0; core < 8; ++core) {
        const QVariantMap entry = mockCore(core, core / 4);
        cores.append(entry);
        (core < 4 ? firstCcx : secondCcx).append(entry);
    }
    m_cpuUnlockStatus = {
        {QStringLiteral("schemaVersion"), 1}, {QStringLiteral("devicePresent"), true},
        {QStringLiteral("mode"), QStringLiteral("linux-replay")},
        {QStringLiteral("physicalCores"), 8}, {QStringLiteral("logicalThreads"), 16},
        {QStringLiteral("topologyState"), QStringLiteral("unlocked")},
        {QStringLiteral("cores"), cores}, {QStringLiteral("ccxAvailable"), true},
        {QStringLiteral("ccxGroups"), QVariantList{
            QVariantMap{{QStringLiteral("ccxId"), 0}, {QStringLiteral("cores"), firstCcx}},
            QVariantMap{{QStringLiteral("ccxId"), 1}, {QStringLiteral("cores"), secondCcx}}}},
        {QStringLiteral("helperInstalled"), true}, {QStringLiteral("licenseInstalled"), true},
        {QStringLiteral("unitInstalled"), true}, {QStringLiteral("helperBundleAvailable"), true},
        {QStringLiteral("service"), QVariantMap{{QStringLiteral("active"), QStringLiteral("active")},
                                                  {QStringLiteral("enabled"), QStringLiteral("enabled")}}},
        {QStringLiteral("updatePersistence"), true},
        {QStringLiteral("linuxReplay"), QVariantMap{
            {QStringLiteral("installed"), true},
            {QStringLiteral("enabled"), true},
            {QStringLiteral("service"), QVariantMap{{QStringLiteral("active"), QStringLiteral("active")},
                                                       {QStringLiteral("enabled"), QStringLiteral("enabled")}}},
            {QStringLiteral("updatePersistence"), true}}},
        {QStringLiteral("efi"), QVariantMap{
            {QStringLiteral("installed"), false},
            {QStringLiteral("partial"), false},
            {QStringLiteral("masterInstalled"), false},
            {QStringLiteral("imageInstalled"), false},
            {QStringLiteral("espImageInstalled"), false},
            {QStringLiteral("imagesMatch"), false},
            {QStringLiteral("bootnumStateInstalled"), false},
            {QStringLiteral("bootEntryConfigured"), false},
            {QStringLiteral("bootEntry"), QVariantMap{{QStringLiteral("present"), false},
                                                        {QStringLiteral("active"), false},
                                                         {QStringLiteral("matching"), false},
                                                         {QStringLiteral("firstInBootOrder"), false},
                                                         {QStringLiteral("effective"), false},
                                                         {QStringLiteral("queryAvailable"), true}}},
            {QStringLiteral("efiGuardPresent"), false},
            {QStringLiteral("uefiRuntimeAvailable"), true},
            {QStringLiteral("espIdentityValid"), false},
            {QStringLiteral("matchingEntryCount"), 0},
            {QStringLiteral("unrecordedMatchingEntries"), false},
            {QStringLiteral("imageHashPresent"), false},
            {QStringLiteral("imageHashStateInstalled"), false},
            {QStringLiteral("imageHashValid"), QVariant{}}}},
        {QStringLiteral("guard"), QVariantMap{{QStringLiteral("state"), QStringLiteral("clear")},
                                               {QStringLiteral("active"), false},
                                               {QStringLiteral("currentBoot"), false}}},
        {QStringLiteral("actions"), QVariantMap{
            {QStringLiteral("test"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("enable"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("efi-enable"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("off"), QVariantMap{{QStringLiteral("available"), true}, {QStringLiteral("blockers"), QVariantList{}}}}}}
    };
    emit snapshotChanged();
    emit cpuUnlockStatusChanged();
    emit meshStatusChanged();
}

void Bc250Bridge::startMockMutation(const QString &label, bool cancellable)
{
    m_operationId = QUuid::createUuid().toString(QUuid::Id128);
    m_operationCancellable = cancellable;
    m_operation = {
        {QStringLiteral("operationId"), m_operationId},
        {QStringLiteral("status"), QStringLiteral("running")},
        {QStringLiteral("label"), label},
        {QStringLiteral("cancellable"), cancellable}
    };
    emit operationChanged();
    m_mockFinishTimer.start();
}
