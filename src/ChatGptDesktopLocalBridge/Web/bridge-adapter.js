(() => {
  if (window.__localBridge) {
    return;
  }

  const REQUEST_START = "[[LOCAL_BRIDGE_REQUEST_V1]]";
  const REQUEST_END = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
  const RESULT_START = "[[LOCAL_BRIDGE_RESULT_V1]]";
  const BOOTSTRAP_START = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";
  const READY_PATTERN = /^\[\[LOCAL_BRIDGE_READY_V1:([a-fA-F0-9]{32})\]\]$/;

  const processed = new Set();
  const pending = new Map();
  const STABLE_MESSAGE_MS = 700;
  let lastSendFailure = null;

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

  const SEND_BUTTON_SELECTORS = [
    "button[data-testid='send-button']",
    "button[data-testid='composer-submit-button']",
    "button[aria-label='Send prompt']",
    "button[aria-label='Send message']",
    "button[aria-label*='Send' i]",
    "button[aria-label*='Отправ' i]"
  ];

  function findSendButton(requireEnabled = true) {
    const composer = findComposer();
    const roots = [];
    const form = composer?.closest?.("form");
    if (form) roots.push(form);
    roots.push(document);

    for (const root of roots) {
      for (const selector of SEND_BUTTON_SELECTORS) {
        const element = root.querySelector(selector);
        if (!element) continue;
        if (!requireEnabled || !element.disabled) return element;
      }
    }

    if (form) {
      const submit = form.querySelector("button[type='submit']");
      if (submit && (!requireEnabled || !submit.disabled)) return submit;
    }

    return null;
  }

  async function waitForSendButton(timeoutMs = 5000) {
    const startedAt = Date.now();

    while (Date.now() - startedAt < timeoutMs) {
      const button = findSendButton(true);
      if (button) return button;
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    return null;
  }

  function postSendResult(token, ok, reason = null) {
    if (!ok) lastSendFailure = reason || "unknown-send-failure";
    else lastSendFailure = null;

    if (!token || !window.chrome?.webview) return;

    window.chrome.webview.postMessage({
      type: "bridge.send_result",
      token,
      ok,
      reason
    });
  }

  function getComposerText(composer) {
    if (!composer) return "";
    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      return composer.value || "";
    }
    return composer.innerText || composer.textContent || "";
  }

  function replaceComposerText(composer, text) {
    composer.focus();

    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      const setter = Object.getOwnPropertyDescriptor(
        Object.getPrototypeOf(composer),
        "value"
      )?.set;

      if (setter) setter.call(composer, text);
      else composer.value = text;

      composer.dispatchEvent(new InputEvent("input", {
        bubbles: true,
        inputType: "insertText",
        data: text
      }));
      composer.dispatchEvent(new Event("change", { bubbles: true }));
      return;
    }

    const selection = window.getSelection();
    const range = document.createRange();
    const insertionRoot = composer.querySelector("p") || composer;
    range.selectNodeContents(insertionRoot);
    range.collapse(true);
    selection?.removeAllRanges();
    selection?.addRange(range);

    let inserted = false;
    try {
      inserted = document.execCommand("insertText", false, text);
    } catch {
      inserted = false;
    }

    if (!inserted || getComposerText(composer).trim() !== text.trim()) {
      try {
        composer.focus();
        document.execCommand("selectAll", false, null);
        inserted = document.execCommand("insertText", false, text);
      } catch {
        inserted = false;
      }
    }

    composer.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function describeComposerState(composer) {
    const buttons = Array.from(document.querySelectorAll("button"))
      .slice(-20)
      .map(button => ({
        testid: button.getAttribute("data-testid"),
        aria: button.getAttribute("aria-label"),
        type: button.getAttribute("type"),
        disabled: Boolean(button.disabled)
      }));

    return JSON.stringify({
      textLength: getComposerText(composer).length,
      html: (composer.innerHTML || "").slice(0, 300),
      buttons
    });
  }

  function sendText(text, token) {
    const composer = findComposer();
    if (!composer) {
      postSendResult(token, false, "composer-not-found");
      return { accepted: false, reason: "composer-not-found" };
    }

    const existing = getComposerText(composer).trim();
    if (existing) {
      postSendResult(token, false, "composer-not-empty");
      return { accepted: false, reason: "composer-not-empty" };
    }

    replaceComposerText(composer, text);

    void (async () => {
      const sendButton = await waitForSendButton();
      if (!sendButton) {
        postSendResult(
          token,
          false,
          "send-button-not-found " + describeComposerState(composer)
        );
        return;
      }

      sendButton.click();
      postSendResult(token, true);
    })();

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

        const readyMatch = text.match(READY_PATTERN);
        if (readyMatch) {
          const session = readyMatch[1];
          const readyKey = "ready:" + session;
          node.style.display = "none";

          if (!processed.has(readyKey) && window.chrome?.webview) {
            processed.add(readyKey);
            window.chrome.webview.postMessage({
              type: "bridge.ready",
              session
            });
          }
          return;
        }

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

  function health() {
    const composer = findComposer();
    const sendButton = findSendButton(false);

    return {
      version: 2,
      href: location.href,
      readyState: document.readyState,
      webViewAvailable: Boolean(window.chrome?.webview),
      composerFound: Boolean(composer),
      composerTag: composer?.tagName || null,
      composerContentEditable: composer?.getAttribute?.("contenteditable") || null,
      sendButtonFound: Boolean(sendButton),
      sendButtonDisabled: sendButton ? Boolean(sendButton.disabled) : null,
      assistantMessages: document.querySelectorAll("[data-message-author-role='assistant']").length,
      userMessages: document.querySelectorAll("[data-message-author-role='user']").length,
      lastSendFailure
    };
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

  window.__localBridge = {
    sendText,
    scan: scheduleScan,
    health,
    version: 2
  };

  const observer = new MutationObserver(scheduleScan);
  observer.observe(document, {
    subtree: true,
    childList: true,
    characterData: true
  });

  scheduleScan();
})();
