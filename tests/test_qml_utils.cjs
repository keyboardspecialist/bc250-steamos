const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync(
    "desktop-control/plasmoid/contents/ui/Utils.js",
    "utf8"
).replace(/^\.pragma library\s*/, "");
const context = {};
vm.createContext(context);
vm.runInContext(source, context);

const unicodeText = "BC-250 \u2713";
assert.strictEqual(
    context.base64Utf8(unicodeText),
    Buffer.from(unicodeText).toString("base64")
);
assert.strictEqual(
    context.shellString("safe"),
    String.fromCharCode(39) + "safe" + String.fromCharCode(39)
);
assert.strictEqual(
    JSON.stringify(context.busValue(JSON.stringify({data: [JSON.stringify({ok: true})]}))),
    JSON.stringify({ok: true})
);
assert.throws(() => context.safeOperationId("unsafe value"));

console.log("QML utility checks passed");
