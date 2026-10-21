#include "Bc250Bridge.h"

#include <QDBusError>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFile>
#include <QMetaMethod>
#include <QRegularExpression>
#include <QUuid>
#include <algorithm>

namespace {
constexpr auto Service = "io.github.keyboardspecialist.BC250Control1";
constexpr auto ObjectPath = "/io/github/keyboardspecialist/BC250Control1";
constexpr auto Interface = "io.github.keyboardspecialist.BC250Control1";
constexpr int PrivilegedCallTimeoutMs = 130000;

bool sandboxed()
{
    return QFile::exists(QStringLiteral("/.flatpak-info")) || qEnvironmentVariableIsSet("FLATPAK_ID");
}

const QStringList CliSections = {QStringLiteral("menu"), QStringLiteral("status"),
    QStringLiteral("setup"), QStringLiteral("toolkit-update"), QStringLiteral("core"),
    QStringLiteral("graphics"), QStringLiteral("devices"), QStringLiteral("maintenance"),
    QStringLiteral("amdgpu-boot"), QStringLiteral("drivers"), QStringLiteral("unlocks"),
    QStringLiteral("storage-updates"), QStringLiteral("interfaces"),
    QStringLiteral("power"), QStringLiteral("ram"), QStringLiteral("swap"),
    QStringLiteral("compute"), QStringLiteral("cpu-unlock"), QStringLiteral("cec"),
    QStringLiteral("storage"), QStringLiteral("persistence"), QStringLiteral("wifi-backend"),
    QStringLiteral("memory-temperature"), QStringLiteral("radv"), QStringLiteral("video-codec"),
    QStringLiteral("proton"), QStringLiteral("manage")};

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
        applyMockMutation();
        m_mockMethod.clear();
        m_mockArguments.clear();
        m_operation.insert(QStringLiteral("status"), QStringLiteral("succeeded"));
        m_operation.insert(QStringLiteral("cancellable"), false);
        emit operationChanged();
        completeOperation(true, message.trimmed());
    });

    if (sandboxed()) {
        m_cliCatalog = {{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("available"), false},
            {QStringLiteral("reason"), QStringLiteral("CLI handoff is unavailable in Flatpak. Use the host toolkit terminal; no sandbox escape is provided.")}};
    }

    if (m_mockMode) {
        setServiceAvailable(true);
        makeMockSnapshot();
        setLoading(false);
        setNotice(QStringLiteral("MOCK MODE: all hardware mutations are simulated."));
        m_snapshotTimer.start();
        return;
    }

    m_serviceWatcher = new QDBusServiceWatcher(QString::fromLatin1(Service), m_bus,
        QDBusServiceWatcher::WatchForRegistration | QDBusServiceWatcher::WatchForUnregistration, this);
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceRegistered, this, [this] {
        rebuildServiceInterface();
        if (m_serviceAvailable)
            refresh();
    });
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceUnregistered, this, [this] {
        if (m_interface) {
            m_interface->deleteLater();
            m_interface = nullptr;
        }
        setServiceAvailable(false);
        setLoading(false);
        if (m_busy)
            fail(QStringLiteral("The BC-250 service disappeared while an operation was active."), true);
        else
            setError(QStringLiteral("The BC-250 system service is unavailable."));
    });

    rebuildServiceInterface();
    m_snapshotTimer.start();
    if (m_serviceAvailable)
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
    updateTelemetryPolling();
}

void Bc250Bridge::setStatusPageActive(bool active)
{
    if (m_statusPageActive == active)
        return;
    m_statusPageActive = active;
    emit statusPageActiveChanged();
    updateTelemetryPolling();
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
    if (!m_cliCatalogPending && !sandboxed())
        requestJson(JsonRequest::CliCatalog, QStringLiteral("GetCliCatalog"));
    if (sandboxed()) {
        m_cliCatalog = {{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("available"), false},
            {QStringLiteral("reason"), QStringLiteral("CLI handoff is unavailable in Flatpak. Use the host toolkit terminal; no sandbox escape is provided.")}};
        emit cliCatalogChanged();
    }
}

void Bc250Bridge::refreshFsr4()
{
    if (m_mockMode) { makeMockSnapshot(); return; }
    if (!m_busy && !m_fsr4Pending && m_serviceAvailable)
        requestJson(JsonRequest::Fsr4, QStringLiteral("GetFsr4Inventory"));
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
            {QStringLiteral("gpuTemp"), 55 + phase / 2},
            {QStringLiteral("sensors"), m_snapshot.value(QStringLiteral("power")).toMap().value(QStringLiteral("sensors"))}
        };
        m_telemetryHistory.append(m_telemetry);
        while (m_telemetryHistory.size() > 36)
            m_telemetryHistory.removeFirst();
        emit telemetryChanged();
        return;
    }
    if (m_serviceAvailable)
        requestJson(JsonRequest::Telemetry, QStringLiteral("GetTelemetry"));
    else
        invalidateTelemetry(QStringLiteral("The system service is offline."));
}

void Bc250Bridge::invalidateTelemetry(const QString &message)
{
    m_telemetry = {{QStringLiteral("cpuClock"), QVariant{}},
        {QStringLiteral("gpuClock"), QVariant{}}, {QStringLiteral("cpuTemp"), QVariant{}},
        {QStringLiteral("gpuTemp"), QVariant{}}, {QStringLiteral("sensors"), QVariantList{}},
        {QStringLiteral("error"), message}};
    m_telemetryHistory.append(m_telemetry);
    while (m_telemetryHistory.size() > 36)
        m_telemetryHistory.removeFirst();
    emit telemetryChanged();
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
    case JsonRequest::Fsr4: m_fsr4Pending = true; break;
    case JsonRequest::CliCatalog: m_cliCatalogPending = true; break;
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
    case JsonRequest::Fsr4: m_fsr4Pending = false; break;
    case JsonRequest::CliCatalog: m_cliCatalogPending = false; break;
    case JsonRequest::Operation: m_operationPending = false; break;
    }

    if (reply.isError()) {
        const QString message = replyError(reply.error());
        if (request == JsonRequest::Telemetry) {
            invalidateTelemetry(message);
        } else if (request == JsonRequest::Operation) {
            if (++m_operationPollFailures >= 8
                || reply.error().name().contains(QStringLiteral("UnknownObject")))
                fail(QStringLiteral("Operation status is no longer available. Refresh before retrying."), true);
            else
                setError(message + QStringLiteral(" Retrying operation status."));
        } else if (request == JsonRequest::Fsr4) {
            const QString reason = reply.error().name().contains(QStringLiteral("UnknownMethod"))
                ? QStringLiteral("The installed service does not provide game management. Update the host service; no hardware CLI fallback is used.")
                : QStringLiteral("Game management unavailable: ") + message;
            m_fsr4Inventory = {{QStringLiteral("available"), false},
                {QStringLiteral("errors"), QVariantList{reason}}};
            emit fsr4InventoryChanged();
        } else if (request == JsonRequest::CliCatalog) {
            m_cliCatalog = {{QStringLiteral("available"), false},
                {QStringLiteral("reason"), QStringLiteral("CLI handoff unavailable: ") + message}};
            emit cliCatalogChanged();
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
                {QStringLiteral("fsr4DllState"), QStringLiteral("not-installed")},
                {QStringLiteral("fsr4DllInstallCount"), 0},
                {QStringLiteral("nativeMeshState"), QStringLiteral("not-installed")},
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
            if (request == JsonRequest::Telemetry)
                invalidateTelemetry(parseError);
            else if (request == JsonRequest::Operation)
                fail(parseError, true);
            else if (request != JsonRequest::Telemetry)
                setError(parseError);
        } else if (request == JsonRequest::Snapshot) {
            m_snapshot = value;
            emit snapshotChanged();
            if (m_preserveErrorOnRefresh) {
                if (!m_snapshotAgain)
                    m_preserveErrorOnRefresh = false;
            } else {
                setError({});
            }
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
        } else if (request == JsonRequest::Fsr4) {
            m_fsr4Inventory = value;
            emit fsr4InventoryChanged();
        } else if (request == JsonRequest::CliCatalog) {
            m_cliCatalog = value;
            emit cliCatalogChanged();
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
    if (mode == QStringLiteral("pin") && (maximum < 350 || maximum > 2230)) {
        reject(QStringLiteral("Pinned frequency must be 350-2230 MHz.")); return;
    }
    if (mode == QStringLiteral("range") && ((minimum != 0 && minimum < 350) || minimum > 2230 || maximum < 350
        || maximum > 2230 || (minimum != 0 && minimum > maximum))) {
        reject(QStringLiteral("GPU frequency range is invalid.")); return;
    }
    if (!ensureReady()) return;
    const int effectiveMinimum = mode == QStringLiteral("range") ? minimum : 0;
    const int effectiveMaximum = mode == QStringLiteral("range") || mode == QStringLiteral("pin")
        ? maximum : 0;
    startMutation(QStringLiteral("SetGpuFrequency"),
        {mode, QVariant::fromValue<uint>(effectiveMinimum),
         QVariant::fromValue<uint>(effectiveMaximum)},
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
    if (minimum < 5 || maximum > 99 || minimum >= maximum) {
        reject(QStringLiteral("Minimum GPU load must be below maximum load and both must be 5-99%.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCustomLoadTarget"),
        {QVariant::fromValue<uchar>(minimum), QVariant::fromValue<uchar>(maximum)},
        QStringLiteral("Applying custom GPU load target"));
}

void Bc250Bridge::setTemperatureTarget(int target)
{
    if (target < 50 || target > 100) {
        reject(QStringLiteral("GPU thermal target must be 50-100 C.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetTemperatureTarget"),
        {QVariant::fromValue<uchar>(target)}, QStringLiteral("Applying GPU thermal target"));
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

void Bc250Bridge::resetGpuRamp()
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("ResetGpuRamp"), {}, QStringLiteral("Resetting GPU ramp"));
}

void Bc250Bridge::gpuVoltageAction(const QString &action, int frequency, int voltage, int newFrequency)
{
    if (!QStringList{QStringLiteral("set"), QStringLiteral("add"), QStringLiteral("edit"),
                     QStringLiteral("remove"), QStringLiteral("offset"), QStringLiteral("reset")}.contains(action)) {
        reject(QStringLiteral("Unknown GPU voltage action.")); return;
    }
    const bool point = action == QStringLiteral("set") || action == QStringLiteral("add")
        || action == QStringLiteral("edit");
    if ((point || action == QStringLiteral("remove")) && (frequency < 350 || frequency > 2230)) {
        reject(QStringLiteral("Curve frequency must be 350-2230 MHz.")); return;
    }
    if (point && (voltage < 700 || voltage > 1050)) {
        reject(QStringLiteral("Curve voltage must be 700-1050 mV.")); return;
    }
    if (action == QStringLiteral("edit") && (newFrequency < 350 || newFrequency > 2230)) {
        reject(QStringLiteral("New curve frequency must be 350-2230 MHz.")); return;
    }
    if (action == QStringLiteral("offset") && (voltage < -350 || voltage > 350)) {
        reject(QStringLiteral("Curve offset must be -350 to 350 mV, keeping every point within 700-1050 mV.")); return;
    }
    // Only the offset voltage is signed. Every unused wire argument is zero.
    if (action == QStringLiteral("reset")) { frequency = 0; voltage = 0; }
    if (action == QStringLiteral("offset")) frequency = 0;
    if (action == QStringLiteral("remove")) voltage = 0;
    if (action != QStringLiteral("edit")) newFrequency = 0;
    const QVariantList saved = m_snapshot.value(QStringLiteral("gpu")).toMap().value(QStringLiteral("safePoints")).toList();
    if (!saved.isEmpty() && action != QStringLiteral("reset")) {
        QList<QPair<int, qint64>> points;
        bool found = false;
        for (const QVariant &entry : saved) {
            const QVariantMap pointValue = entry.toMap();
            int pointFrequency = pointValue.value(QStringLiteral("frequency")).toInt();
            qint64 pointVoltage = pointValue.value(QStringLiteral("voltage")).toLongLong();
            if (pointFrequency == frequency) {
                found = true;
                if (action == QStringLiteral("remove")) continue;
                if (point) pointVoltage = voltage;
                if (action == QStringLiteral("edit")) pointFrequency = newFrequency;
            }
            if (action == QStringLiteral("offset")) pointVoltage += voltage;
            points.append({pointFrequency, pointVoltage});
        }
        if ((action == QStringLiteral("add") && found)
            || ((point || action == QStringLiteral("remove")) && action != QStringLiteral("add") && !found)) {
            reject(QStringLiteral("Curve point does not exist, or the new frequency already exists.")); return;
        }
        if (action == QStringLiteral("add")) points.append({frequency, voltage});
        std::sort(points.begin(), points.end());
        bool valid = points.size() >= 2;
        for (qsizetype i = 0; i < points.size(); ++i) {
            const auto &entry = points.at(i);
            valid = valid && entry.first >= 350 && entry.first <= 2230 && entry.second >= 700 && entry.second <= 1050;
            if (i > 0) valid = valid && points.at(i - 1).first < entry.first && points.at(i - 1).second <= entry.second;
        }
        if (!valid) {
            reject(QStringLiteral("Curve needs at least two unique points, 350-2230 MHz and nondecreasing 700-1050 mV.")); return;
        }
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("GpuVoltageAction"), {action, frequency, voltage, newFrequency},
                  QStringLiteral("Updating GPU curve: ") + action);
}

bool Bc250Bridge::discoveredId(const QString &id, bool candidate) const
{
    static const QRegularExpression pattern(QStringLiteral("^[0-9a-f]{64}$"));
    if (!pattern.match(id).hasMatch()) return false;
    const QString key = candidate ? QStringLiteral("candidateId") : QStringLiteral("targetId");
    const auto contains = [&id, &key](const QVariantList &entries) {
        for (const QVariant &entry : entries)
            if (entry.toMap().value(key).toString() == id) return true;
        return false;
    };
    for (const QVariant &entry : m_fsr4Inventory.value(QStringLiteral("games")).toList()) {
        const QVariantMap game = entry.toMap();
        if (contains(game.value(candidate ? QStringLiteral("optiscalerCandidates") : QStringLiteral("targets")).toList()))
            return true;
    }
    return candidate ? contains(m_fsr4Inventory.value(QStringLiteral("orphanedOptiscaler")).toList())
        : contains(m_fsr4Inventory.value(QStringLiteral("orphanedTargets")).toList())
            || contains(m_fsr4Inventory.value(QStringLiteral("orphanedHelixsr")).toList());
}

void Bc250Bridge::gameMutation(const QString &method, const QString &id, bool candidate, const QString &proxy)
{
    if (!discoveredId(id, candidate)) {
        reject(QStringLiteral("Unknown game target. Refresh the server-discovered inventory.")); return;
    }
    if (!ensureReady()) return;
    QVariantList arguments{id};
    if (!proxy.isEmpty()) arguments.append(proxy);
    startMutation(method, arguments, method, false);
}

void Bc250Bridge::setFsr4Dll(const QString &targetId, bool enabled)
{
    gameMutation(enabled ? QStringLiteral("InstallFsr4Dll") : QStringLiteral("UninstallFsr4Dll"), targetId);
}

void Bc250Bridge::prepareHelixsr()
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("PrepareHelixsr"), {}, QStringLiteral("Preparing experimental HelixSR"), false);
}

void Bc250Bridge::installHelixsr(const QString &targetId)
{ gameMutation(QStringLiteral("InstallHelixsr"), targetId); }
void Bc250Bridge::uninstallHelixsr(const QString &targetId)
{ gameMutation(QStringLiteral("UninstallHelixsr"), targetId); }
void Bc250Bridge::installOptiscaler(const QString &candidateId, const QString &proxy)
{
    if (!QStringList{QStringLiteral("winmm.dll"), QStringLiteral("version.dll"),
                     QStringLiteral("dbghelp.dll"), QStringLiteral("dxgi.dll"),
                     QStringLiteral("d3d12.dll"), QStringLiteral("wininet.dll"),
                     QStringLiteral("winhttp.dll")}.contains(proxy)) {
        reject(QStringLiteral("Unknown OptiScaler proxy.")); return;
    }
    gameMutation(QStringLiteral("InstallOptiscaler"), candidateId, true, proxy);
}
void Bc250Bridge::uninstallOptiscaler(const QString &candidateId)
{ gameMutation(QStringLiteral("UninstallOptiscaler"), candidateId, true); }

void Bc250Bridge::cecAction(const QString &action)
{
    if (!QStringList{QStringLiteral("tv-on"), QStringLiteral("tv-off"), QStringLiteral("amp-on"),
        QStringLiteral("amp-off"), QStringLiteral("switch"), QStringLiteral("release"),
        QStringLiteral("vol-up"), QStringLiteral("vol-down"), QStringLiteral("mute")}.contains(action)) {
        reject(QStringLiteral("Unknown CEC action.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("CecAction"), {action}, QStringLiteral("CEC: ") + action);
}

void Bc250Bridge::setCecToggle(const QString &key, bool enabled)
{
    if (!QStringList{QStringLiteral("wake-tv"), QStringLiteral("suspend-tv"),
                     QStringLiteral("allow-standby"), QStringLiteral("uinput")}.contains(key)) {
        reject(QStringLiteral("Unknown CEC toggle.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCecToggle"), {key, enabled}, QStringLiteral("Updating CEC integration"));
}

void Bc250Bridge::setCecName(const QString &name)
{
    if (name.trimmed().isEmpty() || name.toUtf8().size() > 14
        || name.contains(QLatin1Char('"')) || name.contains(QLatin1Char('\\'))
        || name.contains(QRegularExpression(QStringLiteral("\\p{C}|(?! )\\p{Z}")))) {
        reject(QStringLiteral("CEC name must be printable, 1-14 UTF-8 bytes, without quotes or backslashes.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCecName"), {name}, QStringLiteral("Updating CEC broadcast name"));
}

void Bc250Bridge::openCliSection(const QString &section)
{
    if (sandboxed()) { reject(QStringLiteral("CLI handoff is unavailable in Flatpak.")); return; }
    if (!CliSections.contains(section) || !m_cliCatalog.value(QStringLiteral("available")).toBool()) {
        reject(QStringLiteral("CLI section unavailable. Refresh the native CLI catalog.")); return;
    }
    bool discovered = false;
    for (const QVariant &entry : m_cliCatalog.value(QStringLiteral("sections")).toList())
        if (entry.toMap().value(QStringLiteral("id")).toString() == section) discovered = true;
    if (!discovered) { reject(QStringLiteral("Unknown CLI catalog section.")); return; }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("OpenCliSection"), {section}, QStringLiteral("Opening host-user CLI: ") + section, false);
}

void Bc250Bridge::cpuOcAction(const QString &action, int frequency, int voltage, int temperature)
{
    if (!QStringList{QStringLiteral("detect"), QStringLiteral("apply"), QStringLiteral("enable"),
                     QStringLiteral("off"), QStringLiteral("update")}.contains(action)) {
        reject(QStringLiteral("Unknown CPU overclock action.")); return;
    }
    if (action == QStringLiteral("detect") && (frequency < 3500 || frequency > 4500
        || voltage < 950 || voltage > 1325 || temperature < 50 || temperature > 100)) {
        reject(QStringLiteral("CPU detection values are outside the service safety bounds.")); return;
    }
    if (!ensureReady()) return;
    startMutation(QStringLiteral("CpuOcAction"),
        {action, QVariant::fromValue<uint>(frequency), QVariant::fromValue<uint>(voltage),
         QVariant::fromValue<uint>(temperature)}, QStringLiteral("Running CPU ") + action,
         action != QStringLiteral("update"));
}

void Bc250Bridge::cpuUnlockAction(const QString &action)
{
    if (!QStringList{QStringLiteral("test"), QStringLiteral("enable"), QStringLiteral("efi-enable"),
                     QStringLiteral("off"), QStringLiteral("metrics-enable"),
                     QStringLiteral("uninstall")}.contains(action)) {
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

void Bc250Bridge::setCpuSmtDisabled(bool disabled)
{
    if (!ensureReady()) return;
    startMutation(QStringLiteral("SetCpuSmtDisabled"), {disabled},
                  disabled ? QStringLiteral("Disabling CPU SMT")
                           : QStringLiteral("Enabling CPU SMT"), false);
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
    if (!m_mockMode && !m_capabilities.value(method).toBool()) {
        reject(QStringLiteral("The installed service does not provide ") + method
            + QStringLiteral(". Update the host service; no hardware CLI fallback is used."));
        return;
    }
    m_preserveErrorOnRefresh = false;
    setError({});
    setNotice({});
    m_busy = true;
    m_busyLabel = label;
    m_operationCancellable = cancellable;
    m_operationPollFailures = 0;
    emit busyChanged();
    emit operationChanged();
    if (m_mockMode) {
        startMockMutation(method, arguments, label, cancellable);
        return;
    }
    QDBusMessage message = QDBusMessage::createMethodCall(
        QString::fromLatin1(Service), QString::fromLatin1(ObjectPath),
        QString::fromLatin1(Interface), method);
    message.setArguments(arguments);
    auto *watcher = new QDBusPendingCallWatcher(
        m_bus.asyncCall(message, PrivilegedCallTimeoutMs), this);
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
        m_mockMethod.clear();
        m_mockArguments.clear();
        m_operation.insert(QStringLiteral("status"), QStringLiteral("cancelled"));
        m_operation.insert(QStringLiteral("cancellable"), false);
        emit operationChanged();
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
        m_preserveErrorOnRefresh = false;
        setError({});
        setNotice(sanitizeError(message));
    } else {
        m_preserveErrorOnRefresh = true;
        setError(sanitizeError(message));
    }
    emit operationFinished(success, sanitizeError(message));
    refresh();
    if (!m_fsr4Inventory.isEmpty())
        refreshFsr4();
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
        m_preserveErrorOnRefresh = true;
    }
    setError(message);
}

void Bc250Bridge::clearMessage()
{
    m_preserveErrorOnRefresh = false;
    setError({});
    setNotice({});
}

void Bc250Bridge::setServiceAvailable(bool available)
{
    if (m_serviceAvailable == available)
        return;
    m_serviceAvailable = available;
    if (!available) {
        m_capabilities.clear();
        m_fsr4Inventory.clear();
        m_cliCatalog = {{QStringLiteral("available"), false},
            {QStringLiteral("reason"), sandboxed() ? QStringLiteral("CLI handoff is unavailable in Flatpak.")
                : QStringLiteral("The system service is unavailable.")}};
        emit capabilitiesChanged();
        emit fsr4InventoryChanged();
        emit cliCatalogChanged();
    }
    emit serviceAvailableChanged();
}

void Bc250Bridge::rebuildServiceInterface()
{
    if (m_interface) {
        delete m_interface;
        m_interface = nullptr;
    }
    if (!m_bus.isConnected()) {
        setServiceAvailable(false);
        return;
    }
    m_interface = new QDBusInterface(QString::fromLatin1(Service),
                                     QString::fromLatin1(ObjectPath),
                                     QString::fromLatin1(Interface), m_bus, this);
    setServiceAvailable(m_interface->isValid());
    m_capabilities.clear();
    if (m_serviceAvailable) {
        const QMetaObject *meta = m_interface->metaObject();
        for (int i = meta->methodOffset(); i < meta->methodCount(); ++i)
            m_capabilities.insert(QString::fromLatin1(meta->method(i).name()), true);
    }
    emit capabilitiesChanged();
}

void Bc250Bridge::updateTelemetryPolling()
{
    if (m_visible && m_statusPageActive) {
        m_telemetryTimer.start();
        sampleTelemetry();
    } else {
        m_telemetryTimer.stop();
    }
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
      "gpu":{"available":true,"controllable":true,"dbusReady":true,"mode":"adaptive","requestedMode":"adaptive","requestedMinimum":null,"requestedMaximum":null,"minimum":350,"maximum":1500,"liveMinimum":350,"liveMaximum":1500,"initialMinimum":350,"initialMaximum":1500,"activeMhz":1120,"allowedMinimum":350,"allowedMaximum":2230,"climbMs":500,"loadUpper":0.80,"loadLower":0.65,"temperatureTarget":85,"temperatureRecovery":75,"configuredMax":1500,"persistent":true,"replayApplied":true,"governorService":{"enabled":"enabled","active":"active"},"safePoints":[{"frequency":350,"voltage":700},{"frequency":1500,"voltage":975}]},
      "cpu":{"service":{"enabled":"enabled","active":"active"},"installed":{"values":{"frequency":"4000","voltage":"1275"},"detected":"4000 MHz @ 1275 mV"},"staged":null,"toolAvailable":true,"mitigations":{"schemaVersion":1,"available":true,"state":"enabled","configuredEnabled":true,"bootEnabled":true,"rebootRequired":false,"protected":true},"smt":{"schemaVersion":1,"available":true,"state":"enabled","configuredDisabled":false,"liveDisabled":false,"liveState":"on","protected":true}},
      "ram":{"schemaVersion":1,"available":true,"toolState":"verified","toolVersion":"v0.1","umaLastRequestedMiB":512,"ttmState":"configured","ttmConfiguredPages":3014656,"ttmBootPages":3014656,"ttmLivePages":3014656,"rebootRequired":false,"protected":true},
      "audio":{"available":true,"controllable":true,"state":"active","enabled":true,"active":true,"udevState":"installed","wireplumberState":"installed","persistenceState":"installed","activeProfile":"output:hdmi-ac3-surround"}
    })json";
    if (!m_mockSnapshotInitialized) {
        QString parseError;
        m_snapshot = parseJsonObject(json, &parseError);
        QVariantMap toolkit = m_snapshot.value(QStringLiteral("toolkit")).toMap();
        toolkit.insert(QStringLiteral("cecAvailable"), true);
        toolkit.insert(QStringLiteral("controlApiVersion"), 1);
        toolkit.insert(QStringLiteral("controlCapabilities"), QStringList{
            QStringLiteral("gpu-voltage-curve"), QStringLiteral("gpu-ramp-reset"),
            QStringLiteral("cpu-oc-update"), QStringLiteral("cpu-unlock-metrics"),
            QStringLiteral("cpu-unlock-uninstall"), QStringLiteral("cli-handoff"), QStringLiteral("hwmon-sensors")});
        m_snapshot.insert(QStringLiteral("toolkit"), toolkit);
        m_snapshot.insert(QStringLiteral("cec"), parseJsonObject(R"json({"devicePresent":true,"service":{"enabled":"enabled","active":"active"},"active":true,"poweroffIntegration":true,"sleepIntegration":true,"osdName":"BC250","wakeTv":true,"suspendTv":false,"allowStandby":false,"uinput":true})json"));
        QVariantMap power = m_snapshot.value(QStringLiteral("power")).toMap();
        power.insert(QStringLiteral("sensors"), QVariantList{
            QVariantMap{{QStringLiteral("key"), QStringLiteral("amdgpu:temp1_input")}, {QStringLiteral("device"), QStringLiteral("amdgpu")}, {QStringLiteral("label"), QStringLiteral("edge")}, {QStringLiteral("value"), 57}, {QStringLiteral("unit"), QStringLiteral("C")}},
            QVariantMap{{QStringLiteral("key"), QStringLiteral("nct6687:fan1_input")}, {QStringLiteral("device"), QStringLiteral("nct6687")}, {QStringLiteral("label"), QStringLiteral("CPU fan")}, {QStringLiteral("value"), 1200}, {QStringLiteral("unit"), QStringLiteral("RPM")}},
            QVariantMap{{QStringLiteral("key"), QStringLiteral("nct6687:in0_input")}, {QStringLiteral("device"), QStringLiteral("nct6687")}, {QStringLiteral("label"), QStringLiteral("Vcore")}, {QStringLiteral("value"), 1.05}, {QStringLiteral("unit"), QStringLiteral("V")}}});
        m_snapshot.insert(QStringLiteral("power"), power);
        for (const QString &method : QStringList{QStringLiteral("GpuVoltageAction"), QStringLiteral("ResetGpuRamp"), QStringLiteral("CpuOcAction"), QStringLiteral("CpuUnlockAction"), QStringLiteral("CecAction"), QStringLiteral("SetCecName"), QStringLiteral("SetCecToggle")})
            m_capabilities.insert(method, true);
        m_cliCatalog = {{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("available"), !sandboxed()},
            {QStringLiteral("toolkitVersion"), QStringLiteral("mock source")},
            {QStringLiteral("reason"), sandboxed() ? QVariant(QStringLiteral("CLI handoff is unavailable in Flatpak.")) : QVariant{}}};
        QVariantList sections;
        for (const QString &id : CliSections)
            sections.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("title"), id},
                {QStringLiteral("description"), QStringLiteral("Open fixed toolkit section in the host user's terminal.")},
                {QStringLiteral("risk"), id == QStringLiteral("status") ? QStringLiteral("read-only") : QStringLiteral("maintenance")}});
        m_cliCatalog.insert(QStringLiteral("sections"), sections);
        m_mockSnapshotInitialized = true;
    }
    if (m_fsr4Inventory.isEmpty())
        m_fsr4Inventory = parseJsonObject(R"json({"schemaVersion":1,"available":true,"currentRelease":"mock-fsr4","helixsrAvailable":true,"helixsrPayloadState":"ready","currentHelixsrRelease":"mock-helixsr","optiscalerAvailable":true,"currentOptiscalerRelease":"mock-optiscaler","errors":[],"orphanedTargets":[],"orphanedHelixsr":[],"orphanedOptiscaler":[],"games":[{"appId":"0","name":"Offline mock game","fullyInstalled":true,"installPresent":true,"scanState":"complete","targets":[{"targetId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","relativePath":"amd_fidelityfx_upscaler_dx12.dll","state":"available","discovered":true,"helixsrState":"not-installed","helixsrManaged":false,"optiscalerManaged":false}],"optiscalerCandidates":[{"candidateId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","relativePath":"bin","executables":["mock.exe"],"state":"not-installed","discovered":true,"fsr4Managed":false,"helixsrManaged":false}]}]})json");
    int mockDllCount = 0;
    for (const QVariant &game : m_fsr4Inventory.value(QStringLiteral("games")).toList())
        for (const QVariant &target : game.toMap().value(QStringLiteral("targets")).toList())
            if (QStringList{QStringLiteral("ready"), QStringLiteral("upgrade-required"), QStringLiteral("missing")}
                .contains(target.toMap().value(QStringLiteral("state")).toString())) ++mockDllCount;
    m_meshStatus = {
        {QStringLiteral("scriptAvailable"), true},
        {QStringLiteral("runtimeState"), QStringLiteral("ready")},
        {QStringLiteral("mesaVersion"), QStringLiteral("mesa-26.2.2")},
        {QStringLiteral("directMeshVersion"), QStringLiteral("mock-directmesh")},
        {QStringLiteral("kernelReady"), true},
        {QStringLiteral("schedulerConfigured"), true},
        {QStringLiteral("schedulerActive"), true},
        {QStringLiteral("globalEnabled"), true},
        {QStringLiteral("restartRequired"), false},
        {QStringLiteral("fsr4State"), QStringLiteral("ready")},
        {QStringLiteral("fsr4RunnerPath"), QStringLiteral("/home/deck/.local/share/bc250-mesh-shader/fsr4/bc250-fsr4-run")},
        {QStringLiteral("fsr4DllState"), QStringLiteral("ready")},
        {QStringLiteral("fsr4DllInstallCount"), mockDllCount},
        {QStringLiteral("nativeMeshState"), QStringLiteral("not-installed")},
        {QStringLiteral("nativeMeshIcdPath"), QVariant{}},
        {QStringLiteral("nativeMeshRunnerPath"), QVariant{}}
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
    if (m_cpuUnlockStatus.isEmpty()) {
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
            {QStringLiteral("stateInstalled"), false},
            {QStringLiteral("stateValid"), false},
            {QStringLiteral("licenseInstalled"), false},
            {QStringLiteral("headerLicenseInstalled"), false},
            {QStringLiteral("headersLicenseInstalled"), false},
            {QStringLiteral("licensesInstalled"), false},
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
            {QStringLiteral("imageHashValid"), QVariant{}},
            {QStringLiteral("recoveryStatePresent"), false},
            {QStringLiteral("recoverable"), false}}},
        {QStringLiteral("guard"), QVariantMap{{QStringLiteral("state"), QStringLiteral("clear")},
                                               {QStringLiteral("active"), false},
                                               {QStringLiteral("currentBoot"), false}}},
        {QStringLiteral("actions"), QVariantMap{
            {QStringLiteral("test"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("enable"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("efi-enable"), QVariantMap{{QStringLiteral("available"), false}, {QStringLiteral("blockers"), QVariantList{QStringLiteral("persistent-replay-enabled")}}}},
            {QStringLiteral("off"), QVariantMap{{QStringLiteral("available"), true}, {QStringLiteral("blockers"), QVariantList{}}}}}}
    };
    m_cpuUnlockStatus.insert(QStringLiteral("metrics"), parseJsonObject(R"json({"state":"not-installed","message":"Eight-core topology requires the compatible metrics helper; legacy SMU consumers may be unavailable.","service":{"enabled":"disabled","active":"inactive"},"revision":null})json"));
    QVariantMap actions = m_cpuUnlockStatus.value(QStringLiteral("actions")).toMap();
    for (const QString &action : QStringList{QStringLiteral("metrics-enable"), QStringLiteral("uninstall")})
        actions.insert(action, QVariantMap{{QStringLiteral("available"), true}, {QStringLiteral("blockers"), QVariantList{}}});
    m_cpuUnlockStatus.insert(QStringLiteral("actions"), actions);
    }
    emit snapshotChanged();
    emit cpuUnlockStatusChanged();
    emit meshStatusChanged();
    emit fsr4InventoryChanged();
    emit cliCatalogChanged();
    emit capabilitiesChanged();
}

void Bc250Bridge::startMockMutation(const QString &method, const QVariantList &arguments,
                                    const QString &label, bool cancellable)
{
    m_mockMethod = method;
    m_mockArguments = arguments;
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

void Bc250Bridge::applyMockMutation()
{
    if (QStringList{QStringLiteral("InstallFsr4Dll"), QStringLiteral("UninstallFsr4Dll"),
        QStringLiteral("InstallHelixsr"), QStringLiteral("UninstallHelixsr"),
        QStringLiteral("InstallOptiscaler"), QStringLiteral("UninstallOptiscaler")}.contains(m_mockMethod)) {
        const bool candidate = m_mockMethod.contains(QStringLiteral("Optiscaler"));
        const bool helix = m_mockMethod.contains(QStringLiteral("Helixsr"));
        const bool install = m_mockMethod.startsWith(QStringLiteral("Install"));
        const QString idKey = candidate ? QStringLiteral("candidateId") : QStringLiteral("targetId");
        const QString listKey = candidate ? QStringLiteral("optiscalerCandidates") : QStringLiteral("targets");
        QVariantList games;
        for (const QVariant &entry : m_fsr4Inventory.value(QStringLiteral("games")).toList()) {
            QVariantMap game = entry.toMap();
            QVariantList targets;
            for (const QVariant &item : game.value(listKey).toList()) {
                QVariantMap target = item.toMap();
                if (target.value(idKey).toString() == m_mockArguments.first().toString()) {
                    target.insert(helix ? QStringLiteral("helixsrState") : QStringLiteral("state"),
                        install ? QStringLiteral("ready") : candidate ? QStringLiteral("not-installed") : helix ? QStringLiteral("not-installed") : QStringLiteral("available"));
                    if (helix) target.insert(QStringLiteral("helixsrManaged"), install);
                    if (candidate) {
                        target.insert(QStringLiteral("proxy"), install ? m_mockArguments.at(1) : QVariant{});
                        target.insert(QStringLiteral("currentRelease"), install);
                        target.insert(QStringLiteral("launchOption"), install ? QStringLiteral("MOCK: apply the service-provided launch option manually") : QString());
                    }
                }
                targets.append(target);
            }
            game.insert(listKey, targets);
            games.append(game);
        }
        m_fsr4Inventory.insert(QStringLiteral("games"), games);
        return;
    }
    if (m_mockMethod == QStringLiteral("PrepareHelixsr")) {
        m_fsr4Inventory.insert(QStringLiteral("helixsrPayloadState"), QStringLiteral("ready"));
        return;
    }
    QVariantMap gpu = m_snapshot.value(QStringLiteral("gpu")).toMap();
    if (m_mockMethod == QStringLiteral("SetGpuFrequency") && m_mockArguments.size() == 3) {
        const QString mode = m_mockArguments.at(0).toString();
        const int minimum = m_mockArguments.at(1).toInt();
        const int maximum = m_mockArguments.at(2).toInt();
        const int initialMinimum = gpu.value(QStringLiteral("initialMinimum"), 350).toInt();
        const int initialMaximum = gpu.value(QStringLiteral("initialMaximum"), 1500).toInt();
        gpu.insert(QStringLiteral("mode"), mode);
        gpu.insert(QStringLiteral("requestedMode"), mode);
        if (mode == QStringLiteral("range")) {
            const int liveMinimum = minimum == 0 ? initialMinimum : minimum;
            gpu.insert(QStringLiteral("requestedMinimum"), minimum);
            gpu.insert(QStringLiteral("requestedMaximum"), maximum);
            gpu.insert(QStringLiteral("minimum"), liveMinimum);
            gpu.insert(QStringLiteral("maximum"), maximum);
            gpu.insert(QStringLiteral("liveMinimum"), liveMinimum);
            gpu.insert(QStringLiteral("liveMaximum"), maximum);
        } else if (mode == QStringLiteral("pin")) {
            gpu.insert(QStringLiteral("requestedMinimum"), QVariant{});
            gpu.insert(QStringLiteral("requestedMaximum"), maximum);
            gpu.insert(QStringLiteral("minimum"), maximum);
            gpu.insert(QStringLiteral("maximum"), maximum);
            gpu.insert(QStringLiteral("liveMinimum"), maximum);
            gpu.insert(QStringLiteral("liveMaximum"), maximum);
        } else if (mode == QStringLiteral("max")) {
            gpu.insert(QStringLiteral("requestedMinimum"), QVariant{});
            gpu.insert(QStringLiteral("requestedMaximum"), QVariant{});
            gpu.insert(QStringLiteral("minimum"), initialMaximum);
            gpu.insert(QStringLiteral("maximum"), initialMaximum);
            gpu.insert(QStringLiteral("liveMinimum"), initialMaximum);
            gpu.insert(QStringLiteral("liveMaximum"), initialMaximum);
        } else {
            gpu.insert(QStringLiteral("requestedMinimum"), QVariant{});
            gpu.insert(QStringLiteral("requestedMaximum"), QVariant{});
            gpu.insert(QStringLiteral("minimum"), initialMinimum);
            gpu.insert(QStringLiteral("maximum"), initialMaximum);
            gpu.insert(QStringLiteral("liveMinimum"), initialMinimum);
            gpu.insert(QStringLiteral("liveMaximum"), initialMaximum);
        }
    } else if (m_mockMethod == QStringLiteral("SetLoadTarget") && !m_mockArguments.isEmpty()) {
        const bool eager = m_mockArguments.constFirst().toString() == QStringLiteral("eager");
        gpu.insert(QStringLiteral("loadLower"), eager ? 0.10 : 0.65);
        gpu.insert(QStringLiteral("loadUpper"), eager ? 0.40 : 0.80);
    } else if (m_mockMethod == QStringLiteral("SetCustomLoadTarget")
               && m_mockArguments.size() == 2) {
        gpu.insert(QStringLiteral("loadLower"), m_mockArguments.at(0).toDouble() / 100.0);
        gpu.insert(QStringLiteral("loadUpper"), m_mockArguments.at(1).toDouble() / 100.0);
    } else if (m_mockMethod == QStringLiteral("SetTemperatureTarget")
               && !m_mockArguments.isEmpty()) {
        const int target = m_mockArguments.constFirst().toInt();
        gpu.insert(QStringLiteral("temperatureTarget"), target);
        gpu.insert(QStringLiteral("temperatureRecovery"), target - 10);
    } else if (m_mockMethod == QStringLiteral("SetRamp") && !m_mockArguments.isEmpty()) {
        gpu.insert(QStringLiteral("climbMs"), m_mockArguments.constFirst().toInt());
    } else if (m_mockMethod == QStringLiteral("ResetGpuRamp")) {
        gpu.insert(QStringLiteral("climbMs"), 500);
    } else if (m_mockMethod == QStringLiteral("GpuVoltageAction")) {
        const QString action = m_mockArguments.at(0).toString();
        const int frequency = m_mockArguments.at(1).toInt();
        const int voltage = m_mockArguments.at(2).toInt();
        QVariantList points;
        for (const QVariant &entry : gpu.value(QStringLiteral("safePoints")).toList()) {
            QVariantMap point = entry.toMap();
            const bool match = point.value(QStringLiteral("frequency")).toInt() == frequency;
            if (match && action == QStringLiteral("remove")) continue;
            if ((match && (action == QStringLiteral("set") || action == QStringLiteral("edit"))) || action == QStringLiteral("offset"))
                point.insert(QStringLiteral("voltage"), action == QStringLiteral("offset") ? point.value(QStringLiteral("voltage")).toInt() + voltage : voltage);
            if (match && action == QStringLiteral("edit")) point.insert(QStringLiteral("frequency"), m_mockArguments.at(3));
            points.append(point);
        }
        if (action == QStringLiteral("add")) points.append(QVariantMap{{QStringLiteral("frequency"), frequency}, {QStringLiteral("voltage"), voltage}});
        if (action == QStringLiteral("reset")) {
            points.clear();
            for (const auto &point : QList<QPair<int, int>>{{350,700},{1000,800},{1500,900},{2000,1000},{2230,1000}})
                points.append(QVariantMap{{QStringLiteral("frequency"), point.first}, {QStringLiteral("voltage"), point.second}});
        }
        std::sort(points.begin(), points.end(), [](const QVariant &left, const QVariant &right) {
            return left.toMap().value(QStringLiteral("frequency")).toInt() < right.toMap().value(QStringLiteral("frequency")).toInt();
        });
        gpu.insert(QStringLiteral("safePoints"), points);
    } else if (m_mockMethod == QStringLiteral("CpuUnlockAction") && (m_mockArguments.first().toString() == QStringLiteral("metrics-enable") || m_mockArguments.first().toString() == QStringLiteral("uninstall"))) {
        const bool enabled = m_mockArguments.first().toString() == QStringLiteral("metrics-enable");
        if (!enabled) {
            m_cpuUnlockStatus.insert(QStringLiteral("mode"), QStringLiteral("none"));
            m_cpuUnlockStatus.insert(QStringLiteral("helperInstalled"), false);
            m_cpuUnlockStatus.insert(QStringLiteral("unitInstalled"), false);
            m_cpuUnlockStatus.insert(QStringLiteral("service"), QVariantMap{{QStringLiteral("enabled"), QStringLiteral("disabled")}, {QStringLiteral("active"), QStringLiteral("inactive")}});
        }
        m_cpuUnlockStatus.insert(QStringLiteral("metrics"), QVariantMap{{QStringLiteral("state"), enabled ? QStringLiteral("compatible") : QStringLiteral("not-installed")},
            {QStringLiteral("message"), QStringLiteral("Simulated compatibility helper state; no SMU payload is sent by sampling.")},
            {QStringLiteral("revision"), enabled ? QVariant(QStringLiteral("mock")) : QVariant{}},
            {QStringLiteral("service"), QVariantMap{{QStringLiteral("enabled"), enabled ? QStringLiteral("enabled") : QStringLiteral("disabled")}, {QStringLiteral("active"), enabled ? QStringLiteral("active") : QStringLiteral("inactive")}}}});
        return;
    } else if (m_mockMethod == QStringLiteral("SetCecToggle") || m_mockMethod == QStringLiteral("SetCecName") || m_mockMethod == QStringLiteral("CecAction")) {
        QVariantMap cec = m_snapshot.value(QStringLiteral("cec")).toMap();
        if (m_mockMethod == QStringLiteral("SetCecName")) cec.insert(QStringLiteral("osdName"), m_mockArguments.first());
        if (m_mockMethod == QStringLiteral("SetCecToggle")) {
            const QMap<QString, QString> keys{{QStringLiteral("wake-tv"), QStringLiteral("wakeTv")}, {QStringLiteral("suspend-tv"), QStringLiteral("suspendTv")}, {QStringLiteral("allow-standby"), QStringLiteral("allowStandby")}, {QStringLiteral("uinput"), QStringLiteral("uinput")}};
            cec.insert(keys.value(m_mockArguments.first().toString()), m_mockArguments.at(1));
        }
        if (m_mockMethod == QStringLiteral("CecAction") && QStringList{QStringLiteral("switch"), QStringLiteral("release")}.contains(m_mockArguments.first().toString()))
            cec.insert(QStringLiteral("active"), m_mockArguments.first().toString() == QStringLiteral("switch"));
        m_snapshot.insert(QStringLiteral("cec"), cec);
        return;
    } else {
        return;
    }
    m_snapshot.insert(QStringLiteral("gpu"), gpu);
}
