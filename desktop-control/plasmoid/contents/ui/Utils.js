.pragma library

function integer(value, minimum, maximum) {
    var number = Math.round(Number(value));
    if (!isFinite(number) || number < minimum || number > maximum)
        throw new Error("Numeric argument is outside the allowed range.");
    return String(number);
}

function booleanToken(value) {
    return value ? "true" : "false";
}

function allowed(value, choices) {
    var token = String(value);
    if (choices.indexOf(token) < 0)
        throw new Error("Argument is not in the command allowlist.");
    return token;
}

function safeOperationId(value) {
    var token = String(value);
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(token))
        throw new Error("The service returned an unsafe operation identifier.");
    return token;
}

function safeTargetId(value) {
    var token = String(value);
    if (!/^[0-9a-f]{64}$/.test(token))
        throw new Error("The service returned an unsafe FSR4 target identifier.");
    return token;
}

function safeCandidateId(value) {
    var token = String(value);
    if (!/^[0-9a-f]{64}$/.test(token))
        throw new Error("The service returned an unsafe OptiScaler candidate identifier.");
    return token;
}

// Return exactly one POSIX shell word. Executable DataSource commands are
// interpreted by a shell, so free-form D-Bus strings must pass through here.
function shellString(value) {
    var text = String(value);
    if (/[\u0000-\u001f\u007f]/.test(text))
        throw new Error("Text contains a control character.");
    return "'" + text.replace(/'/g, "'\"'\"'") + "'";
}

function utf8Bytes(text) {
    var result = [];
    for (var index = 0; index < text.length; ++index) {
        var code = text.charCodeAt(index);
        if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
            var low = text.charCodeAt(++index);
            code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        }
        if (code < 0x80) {
            result.push(code);
        } else if (code < 0x800) {
            result.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
        } else if (code < 0x10000) {
            result.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        } else {
            result.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
                        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        }
    }
    return result;
}

function base64Utf8(text) {
    var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var bytes = utf8Bytes(String(text));
    var output = "";
    for (var index = 0; index < bytes.length; index += 3) {
        var first = bytes[index];
        var second = index + 1 < bytes.length ? bytes[index + 1] : 0;
        var third = index + 2 < bytes.length ? bytes[index + 2] : 0;
        output += alphabet.charAt(first >> 2);
        output += alphabet.charAt(((first & 3) << 4) | (second >> 4));
        output += index + 1 < bytes.length
            ? alphabet.charAt(((second & 15) << 2) | (third >> 6)) : "=";
        output += index + 2 < bytes.length ? alphabet.charAt(third & 63) : "=";
    }
    return output;
}

function busValue(stdout) {
    var envelope = JSON.parse(String(stdout).trim());
    if (!envelope || envelope.data === undefined || envelope.data === null)
        return null;
    var value = Array.isArray(envelope.data) ? envelope.data[0] : envelope.data;
    if (typeof value === "string" && (value.charAt(0) === "{" || value.charAt(0) === "["))
        return JSON.parse(value);
    return value;
}

function readableError(data) {
    var text = String(data.stderr || data["stderr"] || "").trim();
    return text || "The system service command failed.";
}

function valueOrDash(value, suffix) {
    return value === null || value === undefined ? "Unavailable" : String(Math.round(value)) + (suffix || "");
}

function cliSection(value) {
    return allowed(value, ["menu", "status", "power", "ram", "swap", "compute",
        "setup", "toolkit-update", "core", "graphics", "devices", "maintenance",
        "amdgpu-boot", "drivers", "unlocks", "storage-updates", "interfaces",
        "cpu-unlock", "cec", "storage", "persistence", "wifi-backend",
        "memory-temperature", "radv", "video-codec", "proton", "manage"]);
}

function wholeNumber(value, minimum, maximum) {
    if (value === null || value === undefined || typeof value === "boolean" || String(value).trim() === "")
        throw new Error("Enter a whole number.");
    var number = Number(value);
    if (!isFinite(number) || Math.floor(number) !== number || number < minimum || number > maximum)
        throw new Error("Enter a whole number from " + minimum + " to " + maximum + ".");
    return number;
}

// Preview exactly one CLI curve transaction. The service revalidates against
// current state; frontend validation is not an authorization boundary.
function voltageChange(points, action, frequency, voltage, newFrequency, gpu) {
    action = allowed(action, ["set", "add", "edit", "remove", "offset", "reset"]);
    var f = 0, v = 0, n = 0;
    if (["set", "add", "edit", "remove"].indexOf(action) >= 0)
        f = wholeNumber(frequency, 350, 2230);
    if (["set", "add", "edit"].indexOf(action) >= 0)
        v = wholeNumber(voltage, 700, 1050);
    if (action === "edit") n = wholeNumber(newFrequency, 350, 2230);
    if (action === "offset") v = wholeNumber(voltage, -350, 350);
    var candidate = (points || []).map(function(point) {
        return { frequency: point.frequency, voltage: point.voltage };
    });
    var found = candidate.some(function(point) { return point.frequency === f; });
    if (["set", "edit", "remove"].indexOf(action) >= 0 && !found)
        throw new Error("Select an existing curve frequency.");
    if (action === "add" && found)
        throw new Error("A point already exists at that frequency.");
    if (action === "reset") {
        candidate = [{frequency:350,voltage:700}, {frequency:1000,voltage:800},
            {frequency:1500,voltage:900}, {frequency:2000,voltage:1000}, {frequency:2230,voltage:1000}];
    } else if (action === "add") {
        candidate.push({ frequency: f, voltage: v });
    } else if (action === "remove") {
        candidate = candidate.filter(function(point) { return point.frequency !== f; });
    } else {
        candidate = candidate.map(function(point) {
            if (action === "offset") point.voltage += v;
            else if (point.frequency === f) {
                point.voltage = v;
                if (action === "edit") point.frequency = n;
            }
            return point;
        });
    }
    candidate.sort(function(a, b) { return a.frequency - b.frequency; });
    if (candidate.length < 2) throw new Error("Keep at least two curve points.");
    for (var index = 0; index < candidate.length; ++index) {
        wholeNumber(candidate[index].frequency, 350, 2230);
        wholeNumber(candidate[index].voltage, 700, 1050);
        if (index && candidate[index].frequency <= candidate[index - 1].frequency)
            throw new Error("Curve frequencies must be unique.");
        if (index && candidate[index].voltage < candidate[index - 1].voltage)
            throw new Error("Voltage must not decrease as frequency increases.");
    }
    var low = candidate[0].frequency, high = candidate[candidate.length - 1].frequency;
    gpu = gpu || {};
    if ((gpu.requestedMode === "pin" || gpu.requestedMode === "range")
            && (gpu.requestedMaximum < low || gpu.requestedMaximum > high
                || (gpu.requestedMode === "range" && gpu.requestedMinimum !== 0
                    && (gpu.requestedMinimum < low || gpu.requestedMinimum > high))))
        throw new Error("The curve must cover the saved frequency mode. Change the mode first.");
    return { args: [action, String(f), String(v), String(n)], points: candidate };
}

function sensorValue(sensor) {
    if (!sensor || sensor.value === null || sensor.value === undefined || !isFinite(Number(sensor.value)))
        return "Unavailable";
    return String(Math.round(Number(sensor.value) * 1000) / 1000) + (sensor.unit ? " " + sensor.unit : "");
}
