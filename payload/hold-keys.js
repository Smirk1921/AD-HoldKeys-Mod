(() => {
  "use strict";

  const MOD_VERSION = "1.1.0";
  const INSTALL_FLAG = "__AD_HOLDKEYS_INSTALLED__";
  const STORAGE_KEY = "ad-holdkeys-ui-v1";
  const STOP_ALL_CODE = "F4";

  if (globalThis[INSTALL_FLAG]) return;
  globalThis[INSTALL_FLAG] = true;

  const keyDefinitions = Object.freeze([
    {
      id: "d",
      key: "d",
      code: "KeyD",
      keyCode: 68,
      hotkey: "F6",
      hotkeyCode: "F6",
      label: "维度提升"
    },
    {
      id: "m",
      key: "m",
      code: "KeyM",
      keyCode: 77,
      hotkey: "F7",
      hotkeyCode: "F7",
      label: "全部最大"
    },
    {
      id: "c",
      key: "c",
      code: "KeyC",
      keyCode: 67,
      hotkey: "F8",
      hotkeyCode: "F8",
      label: "大坍缩"
    },
    {
      id: "g",
      key: "g",
      code: "KeyG",
      keyCode: 71,
      hotkey: "F9",
      hotkeyCode: "F9",
      label: "反物质星系"
    }
  ]);

  const definitionsById = new Map(keyDefinitions.map(definition => [definition.id, definition]));
  const definitionsByHotkey = new Map(keyDefinitions.map(definition => [definition.hotkeyCode, definition]));
  const activeKeys = new Set();

  let panel;
  let titleElement;
  let statusElement;
  let activityDot;
  let collapseButton;
  let dragState;
  let ipcRenderer;

  function readUiState() {
    try {
      const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
      return parsed && typeof parsed === "object" ? parsed : {};
    } catch {
      return {};
    }
  }

  function writeUiState(patch) {
    try {
      const next = { ...readUiState(), ...patch };
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      // UI persistence is optional and must never affect the game.
    }
  }

  try {
    ({ ipcRenderer } = require("electron"));
  } catch {
    ipcRenderer = undefined;
  }

  function syncMainHeartbeat() {
    if (!ipcRenderer || typeof ipcRenderer.send !== "function") return;
    try {
      ipcRenderer.send("ad-holdkeys:heartbeat", activeKeys.size > 0);
    } catch {
      // A renderer-only fallback keeps the original game repeat loop working.
    }
  }

  function dispatchHeartbeatPulse() {
    for (const definition of keyDefinitions) {
      if (!activeKeys.has(definition.id)) continue;
      dispatchSyntheticKey(definition, "keyup");
      dispatchSyntheticKey(definition, "keydown");
    }
  }

  function defineEventValue(event, name, value) {
    try {
      Object.defineProperty(event, name, {
        configurable: true,
        enumerable: true,
        get: () => value
      });
    } catch {
      // Mousetrap reads keyCode first and key as a fallback.
    }
  }

  function dispatchSyntheticKey(definition, type) {
    const event = new KeyboardEvent(type, {
      key: definition.key,
      code: definition.code,
      location: 0,
      repeat: false,
      bubbles: true,
      cancelable: true,
      composed: true
    });

    defineEventValue(event, "keyCode", definition.keyCode);
    defineEventValue(event, "which", definition.keyCode);
    defineEventValue(event, "charCode", type === "keypress" ? definition.keyCode : 0);
    document.dispatchEvent(event);
  }

  function updatePanel() {
    if (!panel) return;

    for (const button of panel.querySelectorAll("[data-key-id]")) {
      const isActive = activeKeys.has(button.dataset.keyId);
      button.classList.toggle("is-active", isActive);
      button.setAttribute("aria-pressed", String(isActive));
    }

    const activeLabels = keyDefinitions
      .filter(definition => activeKeys.has(definition.id))
      .map(definition => definition.key.toUpperCase());
    const isAnyActive = activeLabels.length > 0;

    panel.classList.toggle("is-any-active", isAnyActive);
    if (activityDot) activityDot.hidden = !isAnyActive;
    if (statusElement) {
      statusElement.textContent = isAnyActive
        ? `正在长按：${activeLabels.join(" · ")}`
        : "未启用";
    }
  }

  function startKey(definition) {
    if (!definition || activeKeys.has(definition.id)) return;
    activeKeys.add(definition.id);
    updatePanel();
    syncMainHeartbeat();
    dispatchSyntheticKey(definition, "keydown");
  }

  function stopKey(definition) {
    if (!definition || !activeKeys.has(definition.id)) return;
    try {
      dispatchSyntheticKey(definition, "keyup");
    } finally {
      activeKeys.delete(definition.id);
      updatePanel();
      syncMainHeartbeat();
    }
  }

  function toggleKey(definition) {
    if (!definition) return;
    if (activeKeys.has(definition.id)) stopKey(definition);
    else startKey(definition);
  }

  function stopAll() {
    for (const definition of [...keyDefinitions]) stopKey(definition);
  }

  function clampPanelPosition(x, y) {
    const rect = panel.getBoundingClientRect();
    const maxX = Math.max(0, window.innerWidth - rect.width);
    const maxY = Math.max(0, window.innerHeight - rect.height);
    return {
      x: Math.max(0, Math.min(x, maxX)),
      y: Math.max(0, Math.min(y, maxY))
    };
  }

  function applyExpandedPosition(state) {
    if (typeof state.x === "number" && typeof state.y === "number") {
      const position = clampPanelPosition(state.x, state.y);
      panel.style.left = `${position.x}px`;
      panel.style.top = `${position.y}px`;
      panel.style.right = "auto";
      panel.style.bottom = "auto";
      return;
    }

    panel.style.left = "";
    panel.style.top = "";
    panel.style.right = "";
    panel.style.bottom = "";
  }

  function saveExpandedPosition() {
    if (!panel || panel.classList.contains("is-minimized")) return;
    const rect = panel.getBoundingClientRect();
    writeUiState({ x: Math.round(rect.left), y: Math.round(rect.top) });
  }

  function updateMinimizedUi(minimized) {
    if (titleElement) titleElement.textContent = minimized ? "长按" : "自动长按";
    if (collapseButton) {
      collapseButton.textContent = minimized ? "▸" : "—";
      collapseButton.setAttribute("aria-label", minimized ? "展开面板" : "最小化面板");
    }
    if (panel) panel.setAttribute("aria-expanded", String(!minimized));
  }

  function setPanelMinimized(minimized, persist = true) {
    if (!panel) return;

    if (minimized && !panel.classList.contains("is-minimized")) saveExpandedPosition();
    panel.classList.toggle("is-minimized", minimized);
    if (!minimized) applyExpandedPosition(readUiState());
    updateMinimizedUi(minimized);
    if (persist) writeUiState({ minimized });
  }

  function restorePanelState() {
    const state = readUiState();
    applyExpandedPosition(state);
    setPanelMinimized(state.minimized === true, false);
  }

  function beginDrag(event) {
    if (panel.classList.contains("is-minimized") ||
        event.button !== 0 || event.target.closest("button")) return;

    const rect = panel.getBoundingClientRect();
    dragState = {
      pointerId: event.pointerId,
      offsetX: event.clientX - rect.left,
      offsetY: event.clientY - rect.top
    };

    panel.classList.add("is-dragging");
    event.currentTarget.setPointerCapture(event.pointerId);
    event.preventDefault();
  }

  function moveDrag(event) {
    if (!dragState || event.pointerId !== dragState.pointerId) return;

    const position = clampPanelPosition(
      event.clientX - dragState.offsetX,
      event.clientY - dragState.offsetY
    );
    panel.style.left = `${position.x}px`;
    panel.style.top = `${position.y}px`;
    panel.style.right = "auto";
    panel.style.bottom = "auto";
  }

  function endDrag(event) {
    if (!dragState || event.pointerId !== dragState.pointerId) return;

    panel.classList.remove("is-dragging");
    const rect = panel.getBoundingClientRect();
    writeUiState({ x: Math.round(rect.left), y: Math.round(rect.top) });
    dragState = undefined;
  }

  function createButton(definition) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ad-holdkeys__key";
    button.dataset.keyId = definition.id;
    button.setAttribute("aria-pressed", "false");
    button.setAttribute("aria-label", `${definition.key.toUpperCase()}：${definition.label}，快捷键 ${definition.hotkey}`);
    button.innerHTML = `
      <kbd>${definition.hotkey}</kbd>
      <span class="ad-holdkeys__key-main">${definition.key.toUpperCase()}</span>
      <span class="ad-holdkeys__key-name">${definition.label}</span>
    `;
    return button;
  }

  function createPanel() {
    panel = document.createElement("section");
    panel.id = "ad-holdkeys-panel";
    panel.className = "ad-holdkeys";
    panel.setAttribute("role", "region");
    panel.setAttribute("aria-label", "自动长按控制面板");

    const header = document.createElement("div");
    header.className = "ad-holdkeys__header";
    header.dataset.dragHandle = "true";

    titleElement = document.createElement("span");
    titleElement.className = "ad-holdkeys__title";
    titleElement.textContent = "自动长按";

    activityDot = document.createElement("span");
    activityDot.className = "ad-holdkeys__activity-dot";
    activityDot.hidden = true;
    activityDot.setAttribute("aria-hidden", "true");

    collapseButton = document.createElement("button");
    collapseButton.type = "button";
    collapseButton.className = "ad-holdkeys__collapse";
    collapseButton.setAttribute("aria-label", "最小化面板");
    collapseButton.textContent = "—";

    const headerActions = document.createElement("span");
    headerActions.className = "ad-holdkeys__header-actions";
    headerActions.append(activityDot, collapseButton);
    header.append(titleElement, headerActions);

    const body = document.createElement("div");
    body.className = "ad-holdkeys__body";

    const buttonGrid = document.createElement("div");
    buttonGrid.className = "ad-holdkeys__grid";
    for (const definition of keyDefinitions) buttonGrid.append(createButton(definition));

    const footer = document.createElement("div");
    footer.className = "ad-holdkeys__footer";

    statusElement = document.createElement("span");
    statusElement.className = "ad-holdkeys__status";
    statusElement.textContent = "未启用";

    const stopButton = document.createElement("button");
    stopButton.type = "button";
    stopButton.className = "ad-holdkeys__stop";
    stopButton.dataset.action = "stop-all";
    stopButton.innerHTML = `停止全部 <kbd>${STOP_ALL_CODE}</kbd>`;

    footer.append(statusElement, stopButton);
    body.append(buttonGrid, footer);
    panel.append(header, body);
    document.body.append(panel);

    header.addEventListener("pointerdown", beginDrag);
    header.addEventListener("pointermove", moveDrag);
    header.addEventListener("pointerup", endDrag);
    header.addEventListener("pointercancel", endDrag);

    collapseButton.addEventListener("click", () => {
      setPanelMinimized(!panel.classList.contains("is-minimized"));
    });

    header.addEventListener("click", event => {
      if (panel.classList.contains("is-minimized") && !event.target.closest("button")) {
        setPanelMinimized(false);
      }
    });

    panel.addEventListener("click", event => {
      const stop = event.target.closest("[data-action='stop-all']");
      if (stop) {
        stopAll();
        return;
      }

      const keyButton = event.target.closest("[data-key-id]");
      if (keyButton) toggleKey(definitionsById.get(keyButton.dataset.keyId));
    });

    restorePanelState();
    updatePanel();
  }

  function handleGlobalKeydown(event) {
    if (event.repeat) return;

    if (event.code === STOP_ALL_CODE) {
      event.preventDefault();
      event.stopImmediatePropagation();
      stopAll();
      return;
    }

    const definition = definitionsByHotkey.get(event.code);
    if (!definition) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    toggleKey(definition);
  }

  function install() {
    if (document.getElementById("ad-holdkeys-panel")) return;
    createPanel();
    window.addEventListener("keydown", handleGlobalKeydown, true);
    window.addEventListener("resize", () => {
      if (!panel || panel.classList.contains("is-minimized") || !panel.style.left) return;
      const rect = panel.getBoundingClientRect();
      const position = clampPanelPosition(rect.left, rect.top);
      panel.style.left = `${position.x}px`;
      panel.style.top = `${position.y}px`;
    });
    window.addEventListener("beforeunload", stopAll);
  }

  globalThis.ADHoldKeys = Object.freeze({
    version: MOD_VERSION,
    start: key => startKey(definitionsById.get(String(key).toLowerCase())),
    stop: key => stopKey(definitionsById.get(String(key).toLowerCase())),
    toggle: key => toggleKey(definitionsById.get(String(key).toLowerCase())),
    stopAll,
    setMinimized: value => setPanelMinimized(Boolean(value)),
    activeKeys: () => [...activeKeys],
    __mainTick: dispatchHeartbeatPulse
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  } else {
    install();
  }
})();