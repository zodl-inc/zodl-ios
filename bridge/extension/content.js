// Zodl Bridge content script — spec BR-5: a click listener and NOTHING else.
// Zero DOM mutation, zero page reads beyond the clicked anchor. The page's
// origin is NOT read here — the background uses browser-attested `sender`.
(() => {
  "use strict";

  document.addEventListener(
    "click",
    (event) => {
      // Explicit user gesture is the only trigger (spec §2: drive-by defense).
      if (!event.isTrusted) return;

      const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!anchor) return;

      const href = anchor.getAttribute("href") || "";
      if (!href.startsWith("zcash:")) return;

      // Never let the browser hand the scheme to the OS (spec Invariant 2).
      event.preventDefault();
      event.stopPropagation();

      // BR-7 Tier 1 pointer, if the merchant provides one — absolutized against the
      // page URL (Zodl needs an absolute URL to fetch and origin-compare natively).
      let requestSrc = null;
      const rawSrc = anchor.dataset.zodlRequestSrc;
      if (rawSrc) {
        try {
          requestSrc = new URL(rawSrc, location.href).href;
        } catch {
          requestSrc = null;
        }
      }

      chrome.runtime.sendMessage({
        kind: "zodl-pay-request",
        uri: href,
        requestSrc
      });
    },
    true
  );
})();
