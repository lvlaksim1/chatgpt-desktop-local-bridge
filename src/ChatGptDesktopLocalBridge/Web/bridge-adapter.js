(() => {
  if (window.__localBridge) {
    return;
  }

  const REQUEST_START = "[[LOCAL_BRIDGE_REQUEST_V1]]";
  const REQUEST_END = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
  const RESULT_START = "[[LOCAL_BRIDGE_RESULT_V1]]";
  const BOOTSTRAP_START = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";

  const processed = new Set();

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

  async function sendText(text) {
    const composer = findComposer();
    if (!composer) {
      return { ok: false, reason: "composer-not-found" };
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

    await new Promise(resolve => setTimeout(resolve, 250));

    const sendButton = findSendButton();
    if (!sendButton) {
      return { ok: false, reason: "send-button-not-found" };
    }

    sendButton.click();
    return { ok: true };
  }

  function extractRequest(text) {
    const start = text.indexOf(REQUEST_START);
    if (start < 0) return null;

    const end = text.indexOf(REQUEST_END, start + REQUEST_START.length);
    if (end < 0) return null;

    const raw = text
      .slice(start + REQUEST_START.length, end)
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
    document
      .querySelectorAll("[data-message-author-role='assistant']")
      .forEach(node => {
        const text = node.innerText || "";
        const request = extractRequest(text);
        if (!request) return;

        const key = request.session + ":" + request.id;
        if (processed.has(key)) return;
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
