import fs from "node:fs";
import vm from "node:vm";

const assistantNodes = [];
const userNodes = [];
const posted = [];

globalThis.window = globalThis;
globalThis.location = { href: "https://chatgpt.com/" };
globalThis.document = {
  readyState: "complete",
  querySelector() { return null; },
  querySelectorAll(selector) {
    if (selector.includes("assistant")) return assistantNodes;
    if (selector.includes("user")) return userNodes;
    return [];
  }
};
globalThis.MutationObserver = class {
  constructor(callback) { this.callback = callback; }
  observe() {}
};

window.chrome = {
  webview: {
    postMessage(message) {
      posted.push(message);
    }
  }
};

const adapterPath = new URL("../src/ChatGptDesktopLocalBridge/Web/bridge-adapter.js", import.meta.url);
const source = fs.readFileSync(adapterPath, "utf8");
vm.runInThisContext(source, { filename: "bridge-adapter.js" });

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function messageNode(text) {
  return { innerText: text, textContent: text, style: {} };
}

await sleep(180);

const malformed = messageNode(
  '[[LOCAL_BRIDGE_REQUEST_V1]]\n' +
  '{"session":"0123456789abcdef0123456789abcdef","id":"req-bad","tool":"fs.read_text","args": }\n' +
  '[[/LOCAL_BRIDGE_REQUEST_V1]]'
);
assistantNodes.push(malformed);
window.__localBridge.scan();
await sleep(220);

let health = window.__localBridge.health();
assert(health.version === 6, "Expected adapter v6.");
assert(health.lastProtocolDebug?.stage === "request-rejected", "Malformed request was not marked rejected.");
assert(health.lastProtocolDebug?.reason === "request-json-invalid", "Malformed request reason was not request-json-invalid.");
assert(!posted.some(x => x?.type === "bridge.request" && x?.request?.id === "req-bad"),
  "Malformed request was dispatched.");

const valid = messageNode(
  '[[LOCAL_BRIDGE_REQUEST_V1]]\n' +
  '{"session":"0123456789abcdef0123456789abcdef","id":"req-good","tool":"fs.read_text","args":{"path":"C:/Windows/win.ini","max_chars":4096}}\n' +
  '[[/LOCAL_BRIDGE_REQUEST_V1]]'
);
assistantNodes.push(valid);
window.__localBridge.scan();
await sleep(1100);

health = window.__localBridge.health();
const dispatched = posted.find(x => x?.type === "bridge.request" && x?.request?.id === "req-good");
assert(Boolean(dispatched), "Stable valid request was not dispatched.");
assert(dispatched.request.args.path === "C:/Windows/win.ini", "Valid request path changed.");
assert(valid.style.display === "none", "Dispatched service request was not hidden.");
assert(health.lastProtocolDebug?.stage === "request-dispatched", "Valid request dispatch was not recorded.");
assert(health.protocolProcessedCount >= 1, "Processed count did not advance.");

const readySession = "fedcba9876543210fedcba9876543210";
const ready = messageNode('[[LOCAL_BRIDGE_READY_V1:' + readySession + ']]');
assistantNodes.push(ready);
window.__localBridge.scan();
await sleep(220);

health = window.__localBridge.health();
const readyPosted = posted.find(x => x?.type === "bridge.ready" && x?.session === readySession);
assert(Boolean(readyPosted), "READY marker was not dispatched.");
assert(ready.style.display === "none", "READY service message was not hidden.");
assert(health.lastProtocolDebug?.stage === "ready-dispatched", "READY dispatch was not recorded.");

console.log("bridge-adapter protocol diagnostics test: PASS");
