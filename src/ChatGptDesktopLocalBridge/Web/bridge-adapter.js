(() => {
  if (window.__localBridge) {
    return;
  }

  const REQUEST_START = "[[LOCAL_BRIDGE_REQUEST_V1]]";
  const REQUEST_END = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
  const RESULT_START = "[[LOCAL_BRIDGE_RESULT_V1]]";
  const RESULT_END = "[[/LOCAL_BRIDGE_RESULT_V1]]";
  const BOOTSTRAP_START = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";
  const READY_PATTERN = /^\[\[LOCAL_BRIDGE_READY_V1:([a-fA-F0-9]{32})\]\]$/;

  const processed = new Set();
  const pending = new Map();
  const STABLE_MESSAGE_MS = 700;
  let lastNativeSendDebug = null;
  let lastProtocolDebug = null;

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

  function isBridgeOwnedDraft(text) {
    const normalized = normalizeBridgeText(text).trim();
    return normalized.startsWith(BOOTSTRAP_START) ||
      normalized.startsWith(RESULT_START);
  }

  function selectComposerContents(composer) {
    if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
      composer.select();
      return;
    }

    const selection = window.getSelection();
    if (!selection) return;

    const range = document.createRange();
    range.selectNodeContents(composer);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function prepareNativeSend() {
    const composer = findComposer();
    if (!composer) {
      lastNativeSendDebug = { stage: "prepare", accepted: false, reason: "composer-not-found" };
      return { accepted: false, reason: "composer-not-found" };
    }

    const uiState = getComposerUiState(composer);
    if (!uiState.formFound || !uiState.formInteractive) {
      lastNativeSendDebug = {
        stage: "prepare",
        accepted: false,
        reason: "composer-ui-not-interactive",
        ...uiState
      };
      return {
        accepted: false,
        reason: "composer-ui-not-interactive",
        ...uiState
      };
    }

    const currentText = normalizedComposerText(composer).trim();
    if (currentText.length > 0) {
      if (!isBridgeOwnedDraft(currentText)) {
        lastNativeSendDebug = {
          stage: "prepare",
          accepted: false,
          reason: "composer-not-empty",
          composerTextLength: currentText.length,
          bridgeOwnedDraft: false
        };
        return {
          accepted: false,
          reason: "composer-not-empty",
          composerTextLength: currentText.length,
          bridgeOwnedDraft: false
        };
      }

      composer.focus();
      selectComposerContents(composer);

      lastNativeSendDebug = {
        stage: "prepare",
        accepted: true,
        replacingBridgeDraft: true,
        composerTextLength: currentText.length,
        formFound: Boolean(composer.closest("form"))
      };

      return {
        accepted: true,
        replacingBridgeDraft: true,
        composerTextLength: currentText.length,
        formFound: Boolean(composer.closest("form"))
      };
    }

    composer.focus();
    positionCaretForNativeInput(composer);

    lastNativeSendDebug = {
      stage: "prepare",
      accepted: true,
      replacingBridgeDraft: false,
      formFound: Boolean(composer.closest("form"))
    };

    return {
      accepted: true,
      replacingBridgeDraft: false,
      formFound: Boolean(composer.closest("form"))
    };
  }

  function nativeSendState(expectedText = null) {
    const composer = findComposer();
    const text = normalizedComposerText(composer);
    const meaningfulText = text.trim();

    const uiState = getComposerUiState(composer);

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
      ...uiState
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

  function isVisibleControl(element) {
    if (!element || element.hidden) return false;

    if (typeof element.getBoundingClientRect !== "function") {
      return true;
    }

    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;

    if (typeof window.getComputedStyle !== "function") {
      return true;
    }

    const style = window.getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden";
  }

  function getComposerUiState(composer = findComposer()) {
    const form = composer?.closest("form") || null;
    const buttons = form && typeof form.querySelectorAll === "function"
      ? Array.from(form.querySelectorAll("button"))
      : [];

    let submit = null;
    if (form && typeof form.querySelector === "function") {
      submit =
        form.querySelector("button[data-testid='send-button']") ||
        form.querySelector("#composer-submit-button") ||
        form.querySelector("button[type='submit']");
    }

    const formInteractive = buttons.some(
      button => isVisibleControl(button) && !Boolean(button.disabled)
    );

    const submitFound = Boolean(submit);
    const submitVisible = isVisibleControl(submit);
    const submitDisabled = submitFound ? Boolean(submit.disabled) : null;

    return {
      formFound: Boolean(form),
      formInteractive,
      submitFound,
      submitVisible,
      submitDisabled,
      submitReady: Boolean(submitFound && submitVisible && !submitDisabled)
    };
  }

  function nativeSendReceipt(expectedText, baselineUserMessageCount = 0) {
    const nodes = Array.from(getUserMessageNodes());
    const baseline = Number.isFinite(Number(baselineUserMessageCount))
      ? Math.max(0, Number(baselineUserMessageCount))
      : 0;
    const expectedCanonical = typeof expectedText === "string"
      ? canonicalizeBridgeText(expectedText)
      : "";

    let exactNewUserMessage = false;
    if (expectedCanonical) {
      for (let index = baseline; index < nodes.length; index++) {
        const nodeText = canonicalizeBridgeText(
          nodes[index]?.innerText || nodes[index]?.textContent || ""
        );
        if (nodeText === expectedCanonical) {
          exactNewUserMessage = true;
          break;
        }
      }
    }

    const state = nativeSendState();
    const receipt = {
      composerEmpty: Boolean(state.composerEmpty),
      userMessageCount: nodes.length,
      baselineUserMessageCount: baseline,
      exactNewUserMessage,
      confirmed: Boolean(state.composerEmpty || exactNewUserMessage)
    };

    lastNativeSendDebug = { stage: "receipt", ...receipt };
    return receipt;
  }

  function inspectRequest(text) {
    const normalized = (text || "").trim();
    const hasStart = normalized.includes(REQUEST_START);
    const hasEnd = normalized.includes(REQUEST_END);

    if (!hasStart && !hasEnd) {
      return { candidate: false, complete: false, request: null, reason: null };
    }

    if (!hasStart || !hasEnd) {
      return {
        candidate: true,
        complete: false,
        request: null,
        reason: hasStart ? "request-end-marker-missing" : "request-start-marker-missing"
      };
    }

    if (!normalized.startsWith(REQUEST_START) || !normalized.endsWith(REQUEST_END)) {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-envelope-not-exact"
      };
    }

    const raw = normalized
      .slice(REQUEST_START.length, normalized.length - REQUEST_END.length)
      .trim();

    let request;
    try {
      request = JSON.parse(raw);
    } catch {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-json-invalid"
      };
    }

    if (!request || typeof request !== "object" || Array.isArray(request)) {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-json-not-object"
      };
    }

    if (typeof request.id !== "string" || !request.id) {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-id-missing"
      };
    }

    if (typeof request.session !== "string" || !request.session) {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-session-missing"
      };
    }

    if (typeof request.tool !== "string" || !request.tool) {
      return {
        candidate: true,
        complete: true,
        request: null,
        reason: "request-tool-missing"
      };
    }

    return {
      candidate: true,
      complete: true,
      request,
      reason: null
    };
  }

  function hasResult(session, requestId) {
    if (typeof session !== "string" || !session ||
        typeof requestId !== "string" || !requestId) {
      return false;
    }

    for (const node of getUserMessageNodes()) {
      const normalized = normalizeBridgeText(
        node.textContent || node.innerText || ""
      ).trim();

      if (!normalized.startsWith(RESULT_START) ||
          !normalized.endsWith(RESULT_END)) {
        continue;
      }

      const raw = normalized
        .slice(RESULT_START.length, normalized.length - RESULT_END.length)
        .trim();

      try {
        const result = JSON.parse(raw);
        const resultRequestId = result?.request_id ?? result?.requestId;

        if (result?.session === session && resultRequestId === requestId) {
          return true;
        }
      } catch {
        // A malformed user message must never be treated as a delivered bridge result.
      }
    }

    return false;
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
            lastProtocolDebug = {
              stage: "ready-dispatched",
              sessionPrefix: session.slice(0, 8)
            };
            window.chrome.webview.postMessage({
              type: "bridge.ready",
              session
            });
          }
          return;
        }

        const inspection = inspectRequest(text);
        if (!inspection.candidate) return;

        if (!inspection.complete || !inspection.request) {
          lastProtocolDebug = {
            stage: inspection.complete ? "request-rejected" : "request-partial",
            reason: inspection.reason,
            textLength: text.length
          };
          return;
        }

        const request = inspection.request;
        const key = request.session + ":" + request.id;
        if (processed.has(key)) return;

        const candidate = pending.get(key);
        if (!candidate || candidate.text !== text) {
          pending.set(key, { text, stableSince: now });
          lastProtocolDebug = {
            stage: "request-pending",
            requestId: request.id,
            sessionPrefix: request.session.slice(0, 8),
            tool: request.tool
          };
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
          lastProtocolDebug = {
            stage: "request-dispatched",
            requestId: request.id,
            sessionPrefix: request.session.slice(0, 8),
            tool: request.tool
          };
          window.chrome.webview.postMessage({
            type: "bridge.request",
            request
          });
        }
      });
  }

  function health() {
    const composer = findComposer();
    const uiState = getComposerUiState(composer);

    return {
      version: 10,
      href: location.href,
      readyState: document.readyState,
      webViewAvailable: Boolean(window.chrome?.webview),
      composerFound: Boolean(composer),
      composerTag: composer?.tagName || null,
      composerContentEditable: composer?.getAttribute?.("contenteditable") || null,
      composerFormFound: uiState.formFound,
      composerFormInteractive: uiState.formInteractive,
      submitFound: uiState.submitFound,
      submitReady: uiState.submitReady,
      nativeInputReady: Boolean(composer && uiState.formFound && uiState.formInteractive),
      assistantMessages: getAssistantMessageNodes().length,
      userMessages: getUserMessageNodes().length,
      sendReceiptAvailable: true,
      protocolPendingCount: pending.size,
      protocolProcessedCount: processed.size,
      lastProtocolDebug,
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
    nativeSendReceipt,
    submitNativeSend,
    hasResult,
    scan: scheduleScan,
    health,
    version: 10
  };

  const observer = new MutationObserver(scheduleScan);
  observer.observe(document, {
    subtree: true,
    childList: true,
    characterData: true
  });

  scheduleScan();
})();
