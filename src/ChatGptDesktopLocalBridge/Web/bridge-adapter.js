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
  let lastNativeSendDebug = null;

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

  function getComposerText(composer = findComposer()) {
    if (!composer) return "";

    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      return composer.value || "";
    }

    return composer.innerText || composer.textContent || "";
  }

  function positionCaretForNativeInput(composer) {
    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      const end = composer.value.length;
      composer.setSelectionRange?.(end, end);
      return;
    }

    const selection = window.getSelection();
    if (!selection) return;

    const range = document.createRange();
    const insertionRoot = composer.querySelector("p") || composer;
    range.selectNodeContents(insertionRoot);
    range.collapse(false);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function normalizeBridgeText(value) {
    return (value || "")
      .replace(/\u200B/g, "")
      .replace(/\r\n?/g, "\n");
  }

  function canonicalizeBridgeText(value) {
    return normalizeBridgeText(value)
      .replace(/\s+/g, " ")
      .trim();
  }

  function normalizedComposerText(composer = findComposer()) {
    return normalizeBridgeText(getComposerText(composer));
  }

  function prepareNativeSend() {
    const composer = findComposer();
    if (!composer) {
      lastNativeSendDebug = { stage: "prepare", accepted: false, reason: "composer-not-found" };
      return { accepted: false, reason: "composer-not-found" };
    }

    const currentText = normalizedComposerText(composer).trim();
    if (currentText.length > 0) {
      lastNativeSendDebug = {
        stage: "prepare",
        accepted: false,
        reason: "composer-not-empty",
        composerTextLength: currentText.length
      };
      return {
        accepted: false,
        reason: "composer-not-empty",
        composerTextLength: currentText.length
      };
    }

    composer.focus();
    positionCaretForNativeInput(composer);

    lastNativeSendDebug = {
      stage: "prepare",
      accepted: true,
      formFound: Boolean(composer.closest("form"))
    };

    return {
      accepted: true,
      formFound: Boolean(composer.closest("form"))
    };
  }

  function nativeSendState(expectedText = null) {
    const composer = findComposer();
    const text = normalizedComposerText(composer);
    const meaningfulText = text.trim();

    const state = {
      composerFound: Boolean(composer),
      composerTextLength: text.length,
      composerMeaningfulLength: meaningfulText.length,
      composerEmpty: meaningfulText.length === 0,
      textMatches: typeof expectedText === "string"
        ? canonicalizeBridgeText(text) === canonicalizeBridgeText(expectedText)
        : null,
      expectedCanonicalLength: typeof expectedText === "string"
        ? canonicalizeBridgeText(expectedText).length
        : null,
      actualCanonicalLength: canonicalizeBridgeText(text).length,
      formFound: Boolean(composer?.closest("form"))
    };

    lastNativeSendDebug = { stage: "state", ...state };
    return state;
  }

  function submitNativeSend() {
    const composer = findComposer();
    if (!composer) {
      lastNativeSendDebug = { stage: "submit", accepted: false, reason: "composer-not-found" };
      return { accepted: false, reason: "composer-not-found" };
    }

    const form = composer.closest("form");
    if (!form) {
      lastNativeSendDebug = { stage: "submit", accepted: false, reason: "composer-form-not-found" };
      return { accepted: false, reason: "composer-form-not-found" };
    }

    const currentText = normalizedComposerText(composer).trim();
    if (!currentText) {
      lastNativeSendDebug = { stage: "submit", accepted: false, reason: "composer-empty" };
      return { accepted: false, reason: "composer-empty" };
    }

    try {
      form.requestSubmit();
      lastNativeSendDebug = { stage: "submit", accepted: true, strategy: "requestSubmit" };
      return { accepted: true, strategy: "requestSubmit" };
    } catch (error) {
      lastNativeSendDebug = {
        stage: "submit",
        accepted: false,
        reason: "request-submit-failed",
        detail: String(error)
      };
      return {
        accepted: false,
        reason: "request-submit-failed",
        detail: String(error)
      };
    }
  }

  function getAssistantMessageNodes() {
    return document.querySelectorAll(
      "[data-message-author-role='assistant'], " +
      "[data-markdown-text-style='assistant-message']"
    );
  }

  function getUserMessageNodes() {
    return document.querySelectorAll(
      "[data-message-author-role='user'], " +
      "[data-user-message-bubble='true']"
    );
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
    getUserMessageNodes()
      .forEach(node => {
        const text = node.innerText || "";
        if (text.includes(RESULT_START) || text.includes(BOOTSTRAP_START)) {
          node.style.display = "none";
        }
      });
  }

  function scanAssistantMessages() {
    const now = Date.now();

    getAssistantMessageNodes()
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
    const composerForm = composer?.closest("form") || null;

    return {
      version: 5,
      href: location.href,
      readyState: document.readyState,
      webViewAvailable: Boolean(window.chrome?.webview),
      composerFound: Boolean(composer),
      composerTag: composer?.tagName || null,
      composerContentEditable: composer?.getAttribute?.("contenteditable") || null,
      composerFormFound: Boolean(composerForm),
      nativeInputReady: Boolean(composer && composerForm),
      assistantMessages: getAssistantMessageNodes().length,
      userMessages: getUserMessageNodes().length,
      lastNativeSendDebug
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
    prepareNativeSend,
    nativeSendState,
    submitNativeSend,
    scan: scheduleScan,
    health,
    version: 5
  };

  const observer = new MutationObserver(scheduleScan);
  observer.observe(document, {
    subtree: true,
    childList: true,
    characterData: true
  });

  scheduleScan();
})();
