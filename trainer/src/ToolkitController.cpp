#include "ToolkitController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QVariantList>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <iterator>

#ifdef Q_OS_UNIX
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef Q_OS_MACOS
#include <util.h>
#else
#include <pty.h>
#endif
#endif

namespace {
constexpr qsizetype MaxInventoryBytes = 1024 * 1024;
constexpr qsizetype MaxOutputBytes = 1024 * 1024;
constexpr qsizetype MaxOutputLines = 5000;
constexpr qsizetype MaxQueuedInputBytes = 64 * 1024;
constexpr int InventoryTimeoutMs = 10000;
constexpr int CancelTimeoutMs = 2000;

struct OperationDefinition {
    const char *id;
    const char *title;
    const char *component;
    const char *verb;
    const char *description;
    bool cancellable;
    bool destructive;
};

// Mutating scripts can be in a firmware or filesystem transaction, so they are
// intentionally not eligible for asynchronous process-group termination.
constexpr OperationDefinition Operations[] = {
    {"storage-install", "Install persistent storage", "storage", "INSTALL",
     "Create the persistent data mount and recovery infrastructure.", false, false},
    {"storage-repair", "Repair persistent storage", "storage", "REPAIR",
     "Validate and repair the existing boot and mount infrastructure.", false, false},
    {"storage-remove", "Remove persistent storage", "storage", "REMOVE",
     "Remove storage infrastructure after dependent components are gone; preserved data remains.", false, true},
    {"power-install", "Install power foundation", "power", "INSTALL",
     "Install ACPI support and test-start the GPU governor. Reboot for ACPI, load-test the governor, then run ./bc250-toolkit.sh power to enable it at boot.", false, false},
    {"power-remove", "Remove power and CPU unlock integration", "power", "REMOVE",
     "Disable and remove power services, overrides, and CPU core-unlock boot persistence.", false, true},
    {"ram-install", "Install RAM / VRAM helper", "ram", "INSTALL",
     "Download and verify the memory configuration helper.", false, false},
    {"ram-remove", "Remove RAM / VRAM helper", "ram", "REMOVE",
     "Remove the helper and TTM override while preserving the CMOS split and profile.", false, true},
    {"compute-build", "Build GPU CU prerequisites", "compute", "BUILD UMR",
     "Install dependencies and build UMR only. Live routing, stability testing, saving the table, and boot replay remain separate steps.", false, false},
    {"compute-remove", "Remove GPU CU unlock integration", "compute", "REMOVE",
     "Restore stock GPU routing where possible and remove CU replay integration.", false, true},
    {"cec-setup", "Install CEC integration", "cec", "SET UP",
     "Install the recommended HDMI-CEC behavior and power integration.", false, false},
    {"cec-repair", "Repair CEC integration", "cec", "REPAIR",
     "Recheck adapters, services, permissions, and session integration.", false, false},
    {"cec-remove", "Remove CEC integration", "cec", "REMOVE",
     "Remove toolkit-managed CEC user and system integration.", false, true},
    {"persistence-install", "Protect components across updates", "persistence", "INSTALL",
     "Install SteamOS update retention for every supported component.", false, false},
    {"persistence-remove", "Remove update persistence", "persistence", "REMOVE",
     "Remove all toolkit update-retention entries.", false, true},
    {"aic-install", "Build AIC8800 drivers", "aic", "BUILD + INSTALL",
     "Build and install the matching WiFi and Bluetooth kernel modules.", false, false},
    {"aic-remove", "Remove AIC8800 drivers", "aic", "REMOVE",
     "Unload where possible and remove toolkit-installed modules and firmware.", false, true},
    {"audio-build", "Build AMDGPU kernel fixes", "audio", "BUILD + INSTALL",
     "Install the display/audio, telemetry, and GFX1013 kernel fixes without enabling sched_policy=2. Reboot before RADV setup.", false, false},
    {"audio-remove", "Remove AMDGPU kernel fixes", "audio", "REMOVE",
     "Restore stock AMDGPU module overrides and preserve build caches.", false, true},
    {"mesh-setup", "Build Mesa / RADV async-compute patch", "mesh", "BUILD + INSTALL",
     "Enable GFX1013 async compute after the patched AMDGPU module is active. The build normally takes 3-5 minutes.", false, false},
    {"mesh-remove", "Remove Mesa / RADV async-compute patch", "mesh", "REMOVE",
     "Remove the global alternate runtime and activation while preserving build caches.", false, true},
    {"decky-install", "Install Decky plugin", "decky", "INSTALL",
     "Build and install the BC-250 Decky plugin and privileged helper.", false, false},
    {"decky-remove", "Remove Decky plugin", "decky", "REMOVE",
     "Remove the recognized BC-250 Decky plugin.", false, true},
    {"desktop-install", "Install Plasma control", "desktop", "INSTALL",
     "Install or upgrade the Plasma control and shared service registration.", false, false},
    {"desktop-remove", "Remove Plasma control", "desktop", "REMOVE",
     "Remove the Plasma frontend while preserving shared service users.", false, true},
};

const QByteArray PromptMarker("__BC250_TRAINER_SUDO_PROMPT_7D4A9F2E__");

#ifdef Q_OS_UNIX
void signalChildProcessGroup(qint64 childPid, qint64 childProcessGroup, int signalNumber)
{
    const pid_t pid = static_cast<pid_t>(childPid);
    pid_t group = pid > 0 ? ::getpgid(pid) : -1;
    if (group <= 0)
        group = static_cast<pid_t>(childProcessGroup);
    if (group > 0 && group != ::getpgrp())
        ::kill(-group, signalNumber);
    else if (pid > 0)
        ::kill(pid, signalNumber);
}
#endif
}

ToolkitController::ToolkitController(bool mockMode, const QString &toolkitDirectoryOverride,
                                     QObject *parent)
    : QObject(parent)
    , m_mockMode(mockMode)
    , m_toolkitDirectoryOverride(toolkitDirectoryOverride)
{
    m_childPollTimer.setInterval(50);
    connect(&m_childPollTimer, &QTimer::timeout, this, &ToolkitController::pollChild);
    m_cancelTimer.setSingleShot(true);
    connect(&m_cancelTimer, &QTimer::timeout, this, [this] {
#ifdef Q_OS_UNIX
        if (m_running && m_childPid > 0)
            signalChildProcessGroup(m_childPid, m_childProcessGroup, SIGKILL);
#endif
    });
    m_mockTimer.setSingleShot(true);
    connect(&m_mockTimer, &QTimer::timeout, this, [this] {
        if (m_running)
            finishOperation(0, QStringLiteral("succeeded"));
    });

    refreshInventory();
}

ToolkitController::~ToolkitController()
{
    m_mockTimer.stop();
    m_cancelTimer.stop();
    m_childPollTimer.stop();
    if (m_inventoryProcess) {
        m_inventoryProcess->kill();
        m_inventoryProcess->waitForFinished(1000);
    }
    stopChildImmediately();
}

QVariantMap ToolkitController::result() const
{
    return {{QStringLiteral("status"), m_resultStatus},
            {QStringLiteral("exitCode"), m_exitCode},
            {QStringLiteral("error"), m_error}};
}

QVariantList ToolkitController::operations() const
{
    QVariantList result;
    result.reserve(std::size(Operations));
    for (const OperationDefinition &operation : Operations)
        result.append(operationMetadata(QString::fromLatin1(operation.id)));
    return result;
}

QString ToolkitController::requestedToolkitPath() const
{
    if (!m_toolkitDirectoryOverride.isEmpty())
        return QDir::cleanPath(m_toolkitDirectoryOverride);

    const QString environmentOverride = qEnvironmentVariable("BC250_TOOLKIT_DIR");
    if (!environmentOverride.isEmpty())
        return QDir::cleanPath(environmentOverride);

    return QDir::home().filePath(QStringLiteral(".local/share/bc250-fixes/bc250-steamos"));
}

bool ToolkitController::validateToolkit(QString *canonicalDirectory, QString *error) const
{
    const QFileInfo directoryInfo(requestedToolkitPath());
    const QString canonical = directoryInfo.canonicalFilePath();
    if (canonical.isEmpty() || !directoryInfo.isDir()) {
        if (error)
            *error = QStringLiteral("BC-250 toolkit directory was not found");
        return false;
    }

    const QString launcherPath = QDir(canonical).filePath(QStringLiteral("bc250-toolkit.sh"));
    const QFileInfo launcherInfo(launcherPath);
    if (launcherInfo.isSymLink() || !launcherInfo.exists() || !launcherInfo.isFile()
        || !launcherInfo.isReadable() || launcherInfo.size() <= 0
        || launcherInfo.canonicalFilePath() != launcherInfo.absoluteFilePath()) {
        if (error)
            *error = QStringLiteral("Toolkit launcher is missing, incomplete, or unsafe");
        return false;
    }

#ifdef Q_OS_UNIX
    struct stat launcherStat {};
    if (::lstat(QFile::encodeName(launcherPath).constData(), &launcherStat) != 0
        || !S_ISREG(launcherStat.st_mode) || launcherStat.st_uid != ::geteuid()) {
        if (error)
            *error = QStringLiteral("Toolkit launcher must be a regular file owned by this user");
        return false;
    }
#endif

    if (canonicalDirectory)
        *canonicalDirectory = canonical;
    return true;
}

void ToolkitController::refreshInventory()
{
    if (m_running || m_inventoryProcess)
        return;

    if (m_mockMode) {
        setToolkitPath(requestedToolkitPath());
        setAvailable(true);
        const QVariantMap inventory = mockInventory();
        if (m_inventory != inventory) {
            m_inventory = inventory;
            emit inventoryChanged();
        }
        setError(QString());
        return;
    }

    QString canonicalDirectory;
    QString validationError;
    if (!validateToolkit(&canonicalDirectory, &validationError)) {
        setToolkitPath(requestedToolkitPath());
        setAvailable(false);
        if (!m_inventory.isEmpty()) {
            m_inventory.clear();
            emit inventoryChanged();
        }
        setError(validationError);
        return;
    }

    setToolkitPath(canonicalDirectory);
    setAvailable(true);
    setError(QString());
    m_inventoryStdout.clear();
    m_inventoryStderr.clear();
    m_inventoryFailure.clear();

    auto *process = new QProcess(this);
    m_inventoryProcess = process;
    setRefreshing(true);
    process->setWorkingDirectory(canonicalDirectory);
    process->setProgram(QStringLiteral("/bin/bash"));
    process->setArguments({QStringLiteral("bc250-toolkit.sh"), QStringLiteral("inventory-json")});
    process->setProcessChannelMode(QProcess::SeparateChannels);

    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    environment.remove(QStringLiteral("BASH_ENV"));
    environment.remove(QStringLiteral("BASHOPTS"));
    environment.remove(QStringLiteral("ENV"));
    environment.remove(QStringLiteral("CDPATH"));
    environment.remove(QStringLiteral("GLOBIGNORE"));
    environment.remove(QStringLiteral("SHELLOPTS"));
    environment.remove(QStringLiteral("SUDO_ASKPASS"));
    environment.remove(QStringLiteral("SSH_ASKPASS"));
    for (const QString &key : environment.keys()) {
        if (key.startsWith(QStringLiteral("BASH_FUNC_")))
            environment.remove(key);
    }
    environment.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    environment.insert(QStringLiteral("TERM"), QStringLiteral("dumb"));
    environment.insert(QStringLiteral("SUDO_PROMPT"), authenticationPromptMarker());
    process->setProcessEnvironment(environment);

    const auto collectOutput = [this, process] {
        if (m_inventoryProcess != process)
            return;
        m_inventoryStdout += process->readAllStandardOutput();
        m_inventoryStderr += process->readAllStandardError();
        if (m_inventoryStdout.size() + m_inventoryStderr.size() > MaxInventoryBytes) {
            m_inventoryFailure = QStringLiteral("Toolkit inventory output exceeded the 1 MiB limit");
            process->kill();
        }
    };
    connect(process, &QProcess::readyReadStandardOutput, this, collectOutput);
    connect(process, &QProcess::readyReadStandardError, this, collectOutput);
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError processError) {
        if (m_inventoryProcess == process && processError == QProcess::FailedToStart) {
            m_inventoryProcess = nullptr;
            setRefreshing(false);
            setError(QStringLiteral("Could not start the toolkit inventory process"));
            process->deleteLater();
        }
    });
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process, collectOutput](int code, QProcess::ExitStatus exitStatus) {
        if (m_inventoryProcess != process)
            return;
        collectOutput();
        m_inventoryProcess = nullptr;

        QString parseError;
        if (!m_inventoryFailure.isEmpty()) {
            setError(m_inventoryFailure);
        } else if (exitStatus != QProcess::NormalExit || code != 0) {
            const QString detail = cleanError(QString::fromUtf8(m_inventoryStderr));
            setError(detail.isEmpty()
                         ? QStringLiteral("Toolkit inventory failed with exit code %1").arg(code)
                         : detail);
        } else {
            const QVariantMap parsed = parseInventoryJson(m_inventoryStdout, &parseError);
            if (!parseError.isEmpty()) {
                setError(parseError);
            } else {
                if (m_inventory != parsed) {
                    m_inventory = parsed;
                    emit inventoryChanged();
                }
                setError(QString());
            }
        }
        setRefreshing(false);
        process->deleteLater();
    });

    process->start(QIODevice::ReadOnly);
    process->closeWriteChannel();
    QTimer::singleShot(InventoryTimeoutMs, process, [this, process] {
        if (m_inventoryProcess == process && process->state() != QProcess::NotRunning) {
            m_inventoryFailure = QStringLiteral("Toolkit inventory timed out");
            process->kill();
        }
    });
}

bool ToolkitController::start(const QString &operationId)
{
    if (m_running) {
        setError(QStringLiteral("A toolkit operation is already running"));
        return false;
    }
    if (m_refreshing) {
        setError(QStringLiteral("Toolkit inventory is still being refreshed"));
        return false;
    }

    const QVariantMap metadata = operationMetadata(operationId);
    if (metadata.isEmpty()) {
        m_exitCode = -1;
        m_resultStatus = QStringLiteral("error");
        setError(QStringLiteral("Unknown toolkit operation"));
        emit resultChanged();
        return false;
    }

    if (m_mockMode) {
        beginOperation(metadata);
        appendOutput(QStringLiteral("Mock toolkit operation: %1\n").arg(m_activeOperationTitle));
        m_mockTimer.start(25);
        return true;
    }

    QString canonicalDirectory;
    QString validationError;
    if (!validateToolkit(&canonicalDirectory, &validationError)) {
        setToolkitPath(requestedToolkitPath());
        setAvailable(false);
        m_resultStatus = QStringLiteral("error");
        setError(validationError);
        emit resultChanged();
        return false;
    }
#ifndef Q_OS_UNIX
    Q_UNUSED(canonicalDirectory)
    m_resultStatus = QStringLiteral("error");
    setError(QStringLiteral("Interactive toolkit operations require Unix PTY support"));
    emit resultChanged();
    return false;
#else
    const QByteArray directoryBytes = QFile::encodeName(canonicalDirectory);
    const QByteArray operationBytes = operationId.toUtf8();
    char *childArguments[] = {
        const_cast<char *>("bash"),
        const_cast<char *>("bc250-toolkit.sh"),
        const_cast<char *>("action"),
        const_cast<char *>(operationBytes.constData()),
        nullptr,
    };

    QProcessEnvironment childEnvironment = QProcessEnvironment::systemEnvironment();
    childEnvironment.remove(QStringLiteral("BASH_ENV"));
    childEnvironment.remove(QStringLiteral("BASHOPTS"));
    childEnvironment.remove(QStringLiteral("ENV"));
    childEnvironment.remove(QStringLiteral("CDPATH"));
    childEnvironment.remove(QStringLiteral("GLOBIGNORE"));
    childEnvironment.remove(QStringLiteral("SHELLOPTS"));
    childEnvironment.remove(QStringLiteral("SUDO_ASKPASS"));
    childEnvironment.remove(QStringLiteral("SSH_ASKPASS"));
    for (const QString &key : childEnvironment.keys()) {
        if (key.startsWith(QStringLiteral("BASH_FUNC_")))
            childEnvironment.remove(key);
    }
    childEnvironment.insert(QStringLiteral("SUDO_PROMPT"), authenticationPromptMarker());
    childEnvironment.insert(QStringLiteral("TERM"), QStringLiteral("xterm-256color"));
    const QStringList environmentStrings = childEnvironment.toStringList();
    QList<QByteArray> environmentStorage;
    environmentStorage.reserve(environmentStrings.size());
    for (const QString &entry : environmentStrings)
        environmentStorage.append(entry.toUtf8());
    QList<char *> environmentPointers;
    environmentPointers.reserve(environmentStorage.size() + 1);
    for (QByteArray &entry : environmentStorage)
        environmentPointers.append(entry.data());
    environmentPointers.append(nullptr);
    char **childEnvironmentPointer = environmentPointers.data();
    const char *childDirectory = directoryBytes.constData();

    struct winsize terminalSize {};
    terminalSize.ws_row = 30;
    terminalSize.ws_col = 120;
    int masterFd = -1;
    const pid_t pid = ::forkpty(&masterFd, nullptr, nullptr, &terminalSize);
    if (pid < 0) {
        m_resultStatus = QStringLiteral("error");
        setError(QStringLiteral("Could not create toolkit terminal: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno))));
        emit resultChanged();
        return false;
    }

    if (pid == 0) {
        if (::chdir(childDirectory) != 0)
            _exit(126);
        ::execve("/bin/bash", childArguments, childEnvironmentPointer);
        static constexpr char message[] = "Unable to execute /bin/bash\n";
        ::write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }

    const int currentFlags = ::fcntl(masterFd, F_GETFL, 0);
    if (currentFlags < 0 || ::fcntl(masterFd, F_SETFL, currentFlags | O_NONBLOCK) < 0) {
        const pid_t processGroup = ::getpgid(pid);
        signalChildProcessGroup(pid, processGroup, SIGKILL);
        ::close(masterFd);
        ::waitpid(pid, nullptr, 0);
        m_resultStatus = QStringLiteral("error");
        setError(QStringLiteral("Could not configure the toolkit terminal"));
        emit resultChanged();
        return false;
    }

    m_ptyFd = masterFd;
    m_childPid = pid;
    m_childProcessGroup = ::getpgid(pid);
    m_readNotifier = new QSocketNotifier(masterFd, QSocketNotifier::Read, this);
    connect(m_readNotifier, &QSocketNotifier::activated, this,
            [this](QSocketDescriptor, QSocketNotifier::Type) { drainPty(); });
    m_writeNotifier = new QSocketNotifier(masterFd, QSocketNotifier::Write, this);
    m_writeNotifier->setEnabled(false);
    connect(m_writeNotifier, &QSocketNotifier::activated, this,
            [this](QSocketDescriptor, QSocketNotifier::Type) { flushInput(); });

    beginOperation(metadata);
    m_childPollTimer.start();
    return true;
#endif
}

bool ToolkitController::cancel()
{
    if (!m_running || (!m_cancellable && !m_authenticationPending) || m_cancelPending)
        return false;

    m_cancelPending = true;
    emit cancelPendingChanged();
    if (m_mockMode) {
        m_mockTimer.stop();
        finishOperation(130, QStringLiteral("cancelled"));
        return true;
    }

#ifdef Q_OS_UNIX
    if (m_childPid > 0) {
        signalChildProcessGroup(m_childPid, m_childProcessGroup, SIGTERM);
        m_cancelTimer.start(CancelTimeoutMs);
        return true;
    }
#endif
    return false;
}

bool ToolkitController::submitPassword(const QString &password)
{
    if (!m_authenticationPending)
        return false;
    const bool queued = queueInput(password, true);
    if (queued) {
        m_authenticationPending = false;
        emit authenticationPendingChanged();
    }
    return queued;
}

bool ToolkitController::submitInput(const QString &input)
{
    return queueInput(input, true);
}

bool ToolkitController::queueInput(const QString &input, bool appendNewline)
{
    if (!m_running || m_mockMode || m_ptyFd < 0 || input.contains(QChar::Null))
        return false;

    QByteArray bytes = input.toUtf8();
    if (appendNewline)
        bytes.append('\n');
    if (bytes.size() > MaxQueuedInputBytes - m_pendingInput.size())
        return false;
    m_pendingInput += bytes;
    flushInput();
    return true;
}

void ToolkitController::flushInput()
{
#ifdef Q_OS_UNIX
    while (m_ptyFd >= 0 && !m_pendingInput.isEmpty()) {
        const ssize_t written = ::write(m_ptyFd, m_pendingInput.constData(),
                                        static_cast<size_t>(m_pendingInput.size()));
        if (written > 0) {
            m_pendingInput.remove(0, static_cast<qsizetype>(written));
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        m_pendingInput.clear();
        break;
    }
#endif
    if (m_writeNotifier)
        m_writeNotifier->setEnabled(!m_pendingInput.isEmpty());
}

void ToolkitController::beginOperation(const QVariantMap &metadata)
{
    m_activeOperationId = metadata.value(QStringLiteral("id")).toString();
    m_activeOperationTitle = metadata.value(QStringLiteral("title")).toString();
    m_cancellable = metadata.value(QStringLiteral("cancellable")).toBool();
    m_cancelPending = false;
    m_authenticationPending = false;
    m_running = true;
    m_exitCode = -1;
    m_resultStatus = QStringLiteral("running");
    m_error.clear();
    m_outputText.clear();
    m_markerBuffer.clear();
    m_pendingInput.clear();
    m_pendingCarriageReturn = false;
    m_escapeState = EscapeState::Normal;
    m_utf8Decoder = QStringDecoder(QStringDecoder::Utf8);
    emit activeOperationChanged();
    emit cancelPendingChanged();
    emit authenticationPendingChanged();
    emit outputTextChanged();
    emit errorChanged();
    emit resultChanged();
    emit runningChanged();
}

void ToolkitController::pollChild()
{
#ifdef Q_OS_UNIX
    if (!m_running || m_childPid <= 0)
        return;

    drainPty();
    int status = 0;
    const pid_t pid = static_cast<pid_t>(m_childPid);
    const pid_t result = ::waitpid(pid, &status, WNOHANG);
    if (result == 0)
        return;
    if (result < 0) {
        if (errno == EINTR)
            return;
        flushOutputDecoder();
        closePty();
        finishOperation(-1, QStringLiteral("error"),
                        QStringLiteral("Could not collect toolkit process status"));
        return;
    }

    drainPty();
    flushOutputDecoder();
    closePty();
    if (m_cancelPending) {
        const int code = WIFEXITED(status) ? WEXITSTATUS(status)
                                           : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
        finishOperation(code, QStringLiteral("cancelled"));
    } else if (WIFEXITED(status)) {
        const int code = WEXITSTATUS(status);
        finishOperation(code, code == 0 ? QStringLiteral("succeeded")
                                        : QStringLiteral("failed"));
    } else if (WIFSIGNALED(status)) {
        finishOperation(128 + WTERMSIG(status), QStringLiteral("signaled"));
    } else {
        finishOperation(-1, QStringLiteral("error"),
                        QStringLiteral("Toolkit process ended in an unknown state"));
    }
#endif
}

void ToolkitController::drainPty()
{
#ifdef Q_OS_UNIX
    if (m_ptyFd < 0)
        return;
    char buffer[16384];
    for (;;) {
        const ssize_t count = ::read(m_ptyFd, buffer, sizeof(buffer));
        if (count > 0) {
            consumeBytes(QByteArray(buffer, static_cast<qsizetype>(count)));
            continue;
        }
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            break;
        if (m_readNotifier)
            m_readNotifier->setEnabled(false);
        break;
    }
#endif
}

void ToolkitController::consumeBytes(const QByteArray &bytes)
{
    const QByteArray clean = stripTerminalControls(bytes, &m_escapeState);
    if (!clean.isEmpty())
        consumeDecodedText(m_utf8Decoder(clean));
}

void ToolkitController::consumeDecodedText(const QString &text)
{
    if (text.isEmpty())
        return;
    const QString marker = authenticationPromptMarker();
    m_markerBuffer += text;

    for (;;) {
        const qsizetype markerIndex = m_markerBuffer.indexOf(marker);
        if (markerIndex >= 0) {
            appendNormalized(m_markerBuffer.left(markerIndex));
            m_markerBuffer.remove(0, markerIndex + marker.size());
            if (!m_authenticationPending) {
                m_authenticationPending = true;
                emit authenticationPendingChanged();
            }
            emit authenticationRequested();
            continue;
        }

        qsizetype retained = std::min(marker.size() - 1, m_markerBuffer.size());
        while (retained > 0
               && !marker.startsWith(m_markerBuffer.right(retained)))
            --retained;
        const qsizetype publishLength = m_markerBuffer.size() - retained;
        if (publishLength > 0) {
            appendNormalized(m_markerBuffer.left(publishLength));
            m_markerBuffer.remove(0, publishLength);
        }
        break;
    }
}

void ToolkitController::appendNormalized(const QString &text)
{
    QString normalized;
    normalized.reserve(text.size());
    for (const QChar character : text) {
        if (m_pendingCarriageReturn) {
            if (character == QLatin1Char('\r'))
                continue;
            normalized.append(QLatin1Char('\n'));
            m_pendingCarriageReturn = false;
            if (character == QLatin1Char('\n'))
                continue;
        }
        if (character == QLatin1Char('\r')) {
            m_pendingCarriageReturn = true;
        } else if (character == QLatin1Char('\n') || character == QLatin1Char('\t')
                   || (character.unicode() >= 0x20 && character.unicode() != 0x7f
                       && !(character.unicode() >= 0x80 && character.unicode() <= 0x9f))) {
            normalized.append(character);
        }
    }
    appendOutput(normalized);
}

void ToolkitController::appendOutput(const QString &text)
{
    if (text.isEmpty())
        return;

    m_outputText += text;
    const qsizetype lineCount = m_outputText.count(QLatin1Char('\n'));
    if (lineCount > MaxOutputLines) {
        qsizetype removeLines = lineCount - MaxOutputLines;
        qsizetype position = 0;
        while (removeLines-- > 0) {
            position = m_outputText.indexOf(QLatin1Char('\n'), position);
            if (position < 0)
                break;
            ++position;
        }
        if (position > 0) {
            m_outputText.remove(0, position);
        }
    }

    QByteArray encoded = m_outputText.toUtf8();
    if (encoded.size() > MaxOutputBytes) {
        qsizetype removeBytes = encoded.size() - MaxOutputBytes;
        while (removeBytes < encoded.size()
               && (static_cast<unsigned char>(encoded.at(removeBytes)) & 0xc0) == 0x80)
            ++removeBytes;
        encoded.remove(0, removeBytes);
        m_outputText = QString::fromUtf8(encoded);
    }
    emit outputTextChanged();
}

void ToolkitController::flushOutputDecoder()
{
    const QString finalDecoded = m_utf8Decoder(QByteArray());
    if (!finalDecoded.isEmpty())
        consumeDecodedText(finalDecoded);
    if (!m_markerBuffer.isEmpty()) {
        appendNormalized(m_markerBuffer);
        m_markerBuffer.clear();
    }
    if (m_pendingCarriageReturn) {
        m_pendingCarriageReturn = false;
        appendOutput(QStringLiteral("\n"));
    }
}

void ToolkitController::finishOperation(int exitCode, const QString &status, const QString &error)
{
    const QString finishedId = m_activeOperationId;
    m_childPollTimer.stop();
    m_cancelTimer.stop();
    m_mockTimer.stop();
    m_running = false;
    m_exitCode = exitCode;
    m_resultStatus = status;
    const bool operationStateChanged = m_cancellable;
    const bool cancellationStateChanged = m_cancelPending;
    const bool authenticationStateChanged = m_authenticationPending;
    m_cancellable = false;
    m_cancelPending = false;
    m_authenticationPending = false;
    if (!error.isEmpty())
        setError(error);
    m_pendingInput.clear();
    if (operationStateChanged)
        emit activeOperationChanged();
    if (cancellationStateChanged)
        emit cancelPendingChanged();
    if (authenticationStateChanged)
        emit authenticationPendingChanged();
    emit runningChanged();
    emit resultChanged();
    emit operationFinished(finishedId, status, exitCode);
    if (status != QLatin1String("error"))
        QTimer::singleShot(0, this, &ToolkitController::refreshInventory);
}

void ToolkitController::closePty()
{
    delete m_readNotifier;
    m_readNotifier = nullptr;
    delete m_writeNotifier;
    m_writeNotifier = nullptr;
#ifdef Q_OS_UNIX
    if (m_ptyFd >= 0)
        ::close(m_ptyFd);
#endif
    m_ptyFd = -1;
    m_childPid = -1;
    m_childProcessGroup = -1;
    m_pendingInput.clear();
}

void ToolkitController::stopChildImmediately()
{
#ifdef Q_OS_UNIX
    if (m_childPid > 0) {
        const pid_t pid = static_cast<pid_t>(m_childPid);
        signalChildProcessGroup(m_childPid, m_childProcessGroup, SIGTERM);
        int status = 0;
        for (int attempt = 0; attempt < 20; ++attempt) {
            const pid_t waited = ::waitpid(pid, &status, WNOHANG);
            if (waited == pid || (waited < 0 && errno == ECHILD)) {
                closePty();
                return;
            }
            ::usleep(10000);
        }
        signalChildProcessGroup(m_childPid, m_childProcessGroup, SIGKILL);
        while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
#endif
    closePty();
}

void ToolkitController::clearOutput()
{
    if (m_outputText.isEmpty())
        return;
    m_outputText.clear();
    emit outputTextChanged();
}

void ToolkitController::clearError()
{
    setError(QString());
}

void ToolkitController::setAvailable(bool available)
{
    if (m_available == available)
        return;
    m_available = available;
    emit availableChanged();
}

void ToolkitController::setToolkitPath(const QString &path)
{
    if (m_toolkitPath == path)
        return;
    m_toolkitPath = path;
    emit toolkitPathChanged();
}

void ToolkitController::setRefreshing(bool refreshing)
{
    if (m_refreshing == refreshing)
        return;
    m_refreshing = refreshing;
    emit refreshingChanged();
}

void ToolkitController::setError(const QString &error)
{
    const QString cleaned = cleanError(error);
    if (m_error == cleaned)
        return;
    m_error = cleaned;
    emit errorChanged();
    emit resultChanged();
}

QVariantMap ToolkitController::operationMetadata(const QString &operationId)
{
    for (const OperationDefinition &operation : Operations) {
        if (operationId == QLatin1String(operation.id)) {
            return {{QStringLiteral("id"), operationId},
                    {QStringLiteral("title"), QString::fromLatin1(operation.title)},
                    {QStringLiteral("component"), QString::fromLatin1(operation.component)},
                    {QStringLiteral("verb"), QString::fromLatin1(operation.verb)},
                    {QStringLiteral("description"), QString::fromLatin1(operation.description)},
                    {QStringLiteral("cancellable"), operation.cancellable},
                    {QStringLiteral("destructive"), operation.destructive}};
        }
    }
    return {};
}

QVariantMap ToolkitController::parseInventoryJson(const QByteArray &json, QString *error)
{
    if (error)
        error->clear();
    if (json.size() > MaxInventoryBytes) {
        if (error)
            *error = QStringLiteral("Toolkit inventory JSON exceeded the 1 MiB limit");
        return {};
    }

    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        if (error) {
            *error = parseError.error == QJsonParseError::NoError
                ? QStringLiteral("Toolkit inventory must be a JSON object")
                : QStringLiteral("Invalid toolkit inventory JSON: %1")
                      .arg(parseError.errorString());
        }
        return {};
    }
    return document.object().toVariantMap();
}

QByteArray ToolkitController::stripTerminalControls(const QByteArray &input, EscapeState *state)
{
    QByteArray output;
    output.reserve(input.size());
    EscapeState current = state ? *state : EscapeState::Normal;
    for (const unsigned char byte : input) {
        switch (current) {
        case EscapeState::Normal:
            if (byte == 0x1b) {
                current = EscapeState::Escape;
            } else if ((byte >= 0x20 && byte != 0x7f) || byte == '\n' || byte == '\r'
                       || byte == '\t') {
                output.append(static_cast<char>(byte));
            }
            break;
        case EscapeState::Escape:
            if (byte == '[')
                current = EscapeState::Csi;
            else if (byte == ']')
                current = EscapeState::Osc;
            else
                current = EscapeState::Normal;
            break;
        case EscapeState::Csi:
            if (byte >= 0x40 && byte <= 0x7e)
                current = EscapeState::Normal;
            break;
        case EscapeState::Osc:
            if (byte == 0x07)
                current = EscapeState::Normal;
            else if (byte == 0x1b)
                current = EscapeState::OscEscape;
            break;
        case EscapeState::OscEscape:
            current = byte == '\\' ? EscapeState::Normal : EscapeState::Osc;
            break;
        }
    }
    if (state)
        *state = current;
    return output;
}

QString ToolkitController::normalizeCarriageReturns(const QString &text)
{
    QString normalized;
    normalized.reserve(text.size());
    bool pendingCarriageReturn = false;
    for (const QChar character : text) {
        if (pendingCarriageReturn) {
            if (character == QLatin1Char('\r'))
                continue;
            normalized.append(QLatin1Char('\n'));
            pendingCarriageReturn = false;
            if (character == QLatin1Char('\n'))
                continue;
        }
        if (character == QLatin1Char('\r'))
            pendingCarriageReturn = true;
        else
            normalized.append(character);
    }
    if (pendingCarriageReturn)
        normalized.append(QLatin1Char('\n'));
    return normalized;
}

QString ToolkitController::sanitizedOutput(const QByteArray &output)
{
    EscapeState state = EscapeState::Normal;
    const QByteArray stripped = stripTerminalControls(output, &state);
    QString text = QString::fromUtf8(stripped);
    text.remove(authenticationPromptMarker());
    return normalizeCarriageReturns(text);
}

QString ToolkitController::authenticationPromptMarker()
{
    return QString::fromLatin1(PromptMarker);
}

QString ToolkitController::cleanError(const QString &error)
{
    QString cleaned = sanitizedOutput(error.toUtf8()).trimmed();
    if (cleaned.size() > 1024)
        cleaned = cleaned.left(1021) + QStringLiteral("...");
    return cleaned;
}

QVariantMap ToolkitController::mockInventory() const
{
    const QStringList ids = {QStringLiteral("trainer"), QStringLiteral("desktop"),
                             QStringLiteral("decky"), QStringLiteral("cec"),
                             QStringLiteral("power"), QStringLiteral("ram"),
                             QStringLiteral("compute"), QStringLiteral("mesh"),
                             QStringLiteral("audio"), QStringLiteral("aic"),
                             QStringLiteral("storage")};
    QVariantList components;
    for (const QString &id : ids) {
        components.append(QVariantMap{{QStringLiteral("id"), id},
                                      {QStringLiteral("label"), id},
                                      {QStringLiteral("state"), QStringLiteral("installed")}});
    }
    return {{QStringLiteral("schemaVersion"), 1},
            {QStringLiteral("mock"), true},
            {QStringLiteral("components"), components}};
}
