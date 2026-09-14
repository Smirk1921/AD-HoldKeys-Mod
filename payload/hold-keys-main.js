"use strict";

const { app, ipcMain, powerSaveBlocker } = require("electron");

const HEARTBEAT_MS = 40;
const HEARTBEAT_CHANNEL = "ad-holdkeys:heartbeat";
const TICK_EXPRESSION = "globalThis.ADHoldKeys && globalThis.ADHoldKeys.__mainTick && globalThis.ADHoldKeys.__mainTick();";

let installed = false;
let targetWindow;
let heartbeatTimer;
let powerBlockerId;
let tickInFlight = false;
let tickWatchdog;

function hasUsableWindow() {
  return targetWindow && !targetWindow.isDestroyed() && targetWindow.webContents && !targetWindow.webContents.isDestroyed();
}

function startPowerBlocker() {
  if (powerBlockerId !== undefined && powerSaveBlocker.isStarted(powerBlockerId)) return;
  powerBlockerId = powerSaveBlocker.start("prevent-app-suspension");
}

function stopPowerBlocker() {
  if (powerBlockerId === undefined) return;
  try {
    if (powerSaveBlocker.isStarted(powerBlockerId)) powerSaveBlocker.stop(powerBlockerId);
  } catch {
    // The blocker may already have been released during shutdown.
  }
  powerBlockerId = undefined;
}

function finishTick() {
  if (tickWatchdog !== undefined) clearTimeout(tickWatchdog);
  tickWatchdog = undefined;
  tickInFlight = false;
}

function executeTick() {
  if (tickInFlight || !hasUsableWindow()) return;
  tickInFlight = true;
  tickWatchdog = setTimeout(finishTick, 250);
  targetWindow.webContents.executeJavaScript(TICK_EXPRESSION, true).then(finishTick, finishTick);
}

function startHeartbeat() {
  if (!hasUsableWindow()) return;
  startPowerBlocker();
  if (heartbeatTimer === undefined) heartbeatTimer = setInterval(executeTick, HEARTBEAT_MS);
}

function stopHeartbeat() {
  if (heartbeatTimer !== undefined) clearInterval(heartbeatTimer);
  heartbeatTimer = undefined;
  finishTick();
  stopPowerBlocker();
}

function attachWindow(window) {
  targetWindow = window;
  window.on("closed", () => {
    if (targetWindow === window) targetWindow = undefined;
    stopHeartbeat();
  });
  window.webContents.on("did-start-loading", stopHeartbeat);
}

function install() {
  if (installed) return;
  installed = true;
  ipcMain.on(HEARTBEAT_CHANNEL, (event, enabled) => {
    if (hasUsableWindow() && event.sender !== targetWindow.webContents) return;
    if (enabled) startHeartbeat();
    else stopHeartbeat();
  });
  app.on("before-quit", stopHeartbeat);
}

module.exports = {
  install,
  attachWindow
};