import fs from "node:fs";
import vm from "node:vm";

const assistantNodes = [];
const userNodes = [];
const posted = [];
let composer = null;
let selectedNode = null;

globalThis.window = globalThis;
globalThis.location = { href: "https://chatgpt.com/" };
globalThis.HTMLTextAreaElement = class {};
globalThis.HTMLInputElement = class {};

globalThis.document = {
  readyState: "complete",
  addEventListener() {},
  querySelector() { return composer; },
  querySelectorAll(selector) {
    if (selector.includes("assistant")) return assistantNodes;
    if (selector.includes("user")) return userNodes;
    return [];
  },
  createRange() {
    return {
      selectNodeContents(node) { selectedNode = node; },
      collapse() {}
    };
  }
};

window.getSelection = () => ({
  removeAllRanges() {},
  addRange() {}
});

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

async function waitFor(predicate, timeoutMs = 3000, intervalMs = 25) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(intervalMs);
  }
  return Boolean(predicate());
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function messageNode(text) {
  return { innerText: text, textContent: text, style: {} };
}

function composerNode(text) {
  return {
    innerText: text,
    textContent: text,
    style: {},
    focus() {},
    querySelector() { return null; },
    closest(selector) { return selector === "form" ? {} : null; },
    getAttribute(name) { return name === "contenteditable" ? "true" : null; }
  };
}

await sleep(180);

composer = composerNode("my unsent user draft");
let prepare = window.__localBridge.prepareNativeSend();
assert(prepare.accepted === false, "User draft must block bridge insertion.");
assert(prepare.reason === "composer-not-empty", "User draft rejection reason changed.");
assert(prepare.bridgeOwnedDraft === false, "User draft was misclassified as bridge-owned.");

composer = composerNode(
  "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]\n" +
  "stale bridge-owned service draft"
);
selectedNode = null;
prepare = window.__localBridge.prepareNativeSend();
assert(prepare.accepted === true, "Bridge-owned stale draft should be replaceable.");
assert(prepare.replacingBridgeDraft === true, "Bridge-owned stale draft replacement was not reported.");
assert(selectedNode === composer, "Bridge-owned stale draft contents were not selected for replacement.");

composer = null;

const malformed = messageNode(
  '[[LOCAL_BRIDGE_REQUEST_V1]]\n' +
  '{"session":"0123456789abcdef0123456789abcdef","id":"req-bad","tool":"fs.read_text","args": }\n' +
  '[[/LOCAL_BRIDGE_REQUEST_V1]]'
);
assistantNodes.push(malformed);
window.__localBridge.scan();
assert(
  await waitFor(() => window.__localBridge.health().lastProtocolDebug?.stage === "request-rejected"),
  "Malformed request was not marked rejected."
);

let health = window.__localBridge.health();
assert(health.version === 9, "Expected adapter v9.");
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
assert(
  await waitFor(() => posted.some(x => x?.type === "bridge.request" && x?.request?.id === "req-good")),
  "Stable valid request was not dispatched."
);

health = window.__localBridge.health();
const dispatched = posted.find(x => x?.type === "bridge.request" && x?.request?.id === "req-good");
assert(dispatched.request.args.path === "C:/Windows/win.ini", "Valid request path changed.");
assert(valid.style.display === "none", "Dispatched service request was not hidden.");
assert(health.lastProtocolDebug?.stage === "request-dispatched", "Valid request dispatch was not recorded.");
assert(health.protocolProcessedCount >= 1, "Processed count did not advance.");

const readySession = "fedcba9876543210fedcba9876543210";
const ready = messageNode('[[LOCAL_BRIDGE_READY_V1:' + readySession + ']]');
assistantNodes.push(ready);
window.__localBridge.scan();
assert(
  await waitFor(() => posted.some(x => x?.type === "bridge.ready" && x?.session === readySession)),
  "READY marker was not dispatched."
);

health = window.__localBridge.health();
const readyPosted = posted.find(x => x?.type === "bridge.ready" && x?.session === readySession);
assert(ready.style.display === "none", "READY service message was not hidden.");
assert(health.lastProtocolDebug?.stage === "ready-dispatched", "READY dispatch was not recorded.");

const deliveredResult = messageNode(
  '[[LOCAL_BRIDGE_RESULT_V1]]\n' +
  '{"session":"0123456789abcdef0123456789abcdef","request_id":"req-good","ok":true,"result":{"text":"ok"}}\n' +
  '[[/LOCAL_BRIDGE_RESULT_V1]]'
);
userNodes.push(deliveredResult);
window.__localBridge.scan();
assert(
  await waitFor(() => deliveredResult.style.display === "none"),
  "Bridge result service message was not hidden."
);

assert(
  window.__localBridge.hasResult("0123456789abcdef0123456789abcdef", "req-good") === true,
  "Delivered bridge result was not detected in the current conversation.");
assert(
  window.__localBridge.hasResult("0123456789abcdef0123456789abcdef", "req-other") === false,
  "Result detection matched the wrong request id.");
assert(
  window.__localBridge.hasResult("fedcba9876543210fedcba9876543210", "req-good") === false,
  "Result detection matched the wrong session.");


composer = composerNode("still pending");
const priorPrompt = messageNode("same service prompt");
userNodes.push(priorPrompt);
let receipt = window.__localBridge.nativeSendReceipt("same service prompt", userNodes.length);
assert(receipt.exactNewUserMessage === false,
  "Send receipt matched a user message that existed before the send baseline.");
assert(receipt.confirmed === false,
  "Send receipt was confirmed without composer clearing or a new exact user message.");

const sentPrompt = messageNode("same service prompt");
userNodes.push(sentPrompt);
receipt = window.__localBridge.nativeSendReceipt("same service prompt", userNodes.length - 1);
assert(receipt.exactNewUserMessage === true,
  "Send receipt did not detect the exact newly added user message.");
assert(receipt.confirmed === true,
  "Exact new user message did not confirm the send receipt.");
assert(receipt.userMessageCount === userNodes.length,
  "Send receipt reported the wrong user-message count.");
composer = null;
console.log("bridge-adapter protocol diagnostics test: PASS");
