// Zodl Bridge background — the only place that talks to the native helper.
// One-way (spec Invariant 3): fire the request, surface a local delivery ack,
// never receive wallet data of any kind.
"use strict";

const HOST = "com.zodl.bridge";
const COOLDOWN_MS = 5000;

// Per-origin throttle: one in flight + cooldown (spec §2 request-spam defense).
const lastSent = new Map();
let inFlight = false;

function notify(title, message) {
  chrome.notifications?.create({
    type: "basic",
    iconUrl: "icon128.png",
    title,
    message
  });
}

function deliver(uri, origin, requestSrc, respond) {
  if (inFlight) {
    respond({ ok: false, reason: "busy" });
    return;
  }
  const last = lastSent.get(origin) || 0;
  if (Date.now() - last < COOLDOWN_MS) {
    respond({ ok: false, reason: "cooldown" });
    return;
  }

  inFlight = true;
  lastSent.set(origin, Date.now());

  const message = {
    v: 1,
    id: crypto.randomUUID(),
    type: "payRequest",
    uri,
    origin,
    requestSrc: requestSrc || null
  };

  chrome.runtime.sendNativeMessage(HOST, message, (ack) => {
    inFlight = false;
    if (chrome.runtime.lastError) {
      notify("Zodl Bridge", "Could not reach the Zodl helper. Is it installed? (install-dev.sh)");
      respond({ ok: false, reason: "no-host" });
      return;
    }
    if (ack && ack.status === "received") {
      notify("Zodl Bridge", "Payment request handed to Zodl — review it there.");
      respond({ ok: true });
    } else {
      notify("Zodl Bridge", `Zodl did not accept the request (${ack?.reason ?? "unknown"}).`);
      respond({ ok: false, reason: ack?.reason ?? "rejected" });
    }
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.kind !== "zodl-pay-request") return false;
  // Only our own content scripts / popup — never other extensions.
  if (sender.id !== chrome.runtime.id) return false;

  // Origin is browser-attested (`sender.origin` = the sending frame's origin);
  // page-supplied values are never trusted for identity (spec BR-7 reasoning).
  // Our own extension origin = the popup's paste box → labeled "popup:".
  const ownOrigin = "chrome-extension://" + chrome.runtime.id;
  let origin;
  if (sender.origin === ownOrigin) origin = "popup:";
  else if (sender.origin) origin = sender.origin;
  else if (sender.tab?.url) origin = new URL(sender.tab.url).origin;
  else origin = "popup:";

  deliver(String(message.uri || ""), origin, message.requestSrc, sendResponse);
  return true; // async respond
});
