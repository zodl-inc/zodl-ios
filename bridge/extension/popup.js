// Popup paste box — the permission-light manual path (origin: "popup:").
"use strict";

document.getElementById("send").addEventListener("click", () => {
  const uri = document.getElementById("uri").value.trim();
  const status = document.getElementById("status");
  if (!uri.startsWith("zcash:")) {
    status.textContent = "Not a zcash: payment request.";
    return;
  }
  status.textContent = "Sending…";
  chrome.runtime.sendMessage({ kind: "zodl-pay-request", uri, requestSrc: null }, (result) => {
    status.textContent = result?.ok
      ? "Handed to Zodl — review it there."
      : `Not delivered (${result?.reason ?? "unknown"}).`;
  });
});
