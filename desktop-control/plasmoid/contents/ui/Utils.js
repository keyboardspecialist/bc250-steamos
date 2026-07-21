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
