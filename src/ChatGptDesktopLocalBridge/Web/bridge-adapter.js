(() => {
  if (window.__localBridge) {
    return;
  }

  const REQUEST_START = "[[LOCAL_BRIDGE_REQUEST_V1]]";
  const REQUEST_END = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
  const RESULT_START = "[[LOCAL_BRIDGE_RESULT_V1]]";
  const BOOTSTRAP_START = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";

  const processed = new Set();
  const pending = new Map();
  const STABLE_MESSAGE_MS = 700;

  function findComposer() {
    const selectors = [
      "#prompt-textarea",
      "textarea[data-testid='prompt-textarea']",
      "div[contenteditable='true'][data-testid='prompt-textarea']",
      "div[contenteditable='true'][role='textbox']"
    ];

    for (const selector of selectors) {
      const element = document.querySelector(selector);
      if (element) return element;
    }

    return null;
  }

  function findSendButton() {
    const selectors = [
      "button[data-testid='send-button']",
      "button[aria-label='Send prompt']",
      "button[aria-label='Send message']",
      "button[aria-label*='Send']"
    ];

    for (const selector of selectors) {
      const element = document.querySelector(selector);
      if (element && !element.disabled) return element;
    }

    return null;
  }

  function postSendResult(token, ok, reason = null) {
    if (!token || !window.chrome?.webview) return;

    window.chrome.webview.postMessage({
      type: "bridge.send_result",
      token,
      ok,
      reason
    });
  }

  function sendText(text, token) {
    const composer = findComposer();
    if (!composer) {
      postSendResult(token, false, "composer-not-found");
      return { accepted: false, reason: "composer-not-found" };
    }

    composer.focus();

    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      const setter = Object.getOwnPropertyDescriptor(
        Object.getPrototypeOf(composer),
        "value"
      )?.set;

      if (setter) setter.call(composer, text);
      else composer.value = text;
    } else {
      composer.textContent = text;
    }

    composer.dispatchEvent(new InputEvent("input", {
      bubbles: true,
      inputType: "insertText",
      data: text
    }));

    composer.dispatchEvent(new Event("change", { bubbles: true }));

    setTimeout(() => {
      const sendButton = findSendButton();
      if (!sendButton) {
        postSendResult(token, false, "send-button-not-found");
        return;
      }

      sendButton.click();
      postSendResult(token, true);
    }, 250);

    return { accepted: true };
  }

  function extractRequest(text) {
    const normalized = (text || "").trim();
    if (!normalized.startsWith(REQUEST_START) || !normalized.endsWith(REQUEST_END)) {
      return null;
    }

    const raw = normalized
      .slice(REQUEST_START.length, normalized.length - REQUEST_END.length)
      .trim();

    try {
      const request = JSON.parse(raw);
      if (!request || typeof request !== "object") return null;
      if (typeof request.id !== "string" || !request.id) return null;
      if (typeof request.session !== "string" || !request.session) return null;
      if (typeof request.tool !== "string" || !request.tool) return null;
      return request;
    } catch {
      return null;
    }
  }

  function hideServiceMessages() {
    document
      .querySelectorAll("[data-message-author-role='user']")
      .forEach(node => {
        const text = node.innerText || "";
        if (text.includes(RESULT_START) || text.includes(BOOTSTRAP_START)) {
          node.style.display = "none";
        }
      });
  }

  function scanAssistantMessages() {
    const now = Date.now();

    document
      .querySelectorAll("[data-message-author-role='assistant']")
      .forEach(node => {
        const text = (node.innerText || "").trim();
        const request = extractRequest(text);
        if (!request) return;

        const key = request.session + ":" + request.id;
        if (processed.has(key)) return;

        const candidate = pending.get(key);
        if (!candidate || candidate.text !== text) {
          pending.set(key, { text, stableSince: now });
          setTimeout(scheduleScan, STABLE_MESSAGE_MS + 50);
          return;
        }

        if (now - candidate.stableSince < STABLE_MESSAGE_MS) {
          setTimeout(scheduleScan, STABLE_MESSAGE_MS - (now - candidate.stableSince) + 50);
          return;
        }

        pending.delete(key);
        processed.add(key);
        node.style.display = "none";

        if (window.chrome?.webview) {
          window.chrome.webview.postMessage({
            type: "bridge.request",
            request
          });
        }
      });
  }

  let scheduled = false;
  function scheduleScan() {
    if (scheduled) return;
    scheduled = true;

    setTimeout(() => {
      scheduled = false;
      hideServiceMessages();
      scanAssistantMessages();
    }, 120);
  }

  const observer = new MutationObserver(scheduleScan);
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    characterData: true
  });

  window.__localBridge = {
    sendText,
    scan: scheduleScan,
    version: 1
  };

  scheduleScan();
})();
