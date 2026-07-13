# Zodl Bridge — Safari (macOS) dev harness

Chrome/Brave load the extension unpacked; **Safari cannot** — a Safari Web Extension
must live inside a signed native app. This folder is a throwaway wrapper (Apple's
`safari-web-extension-converter` output) around the SAME `bridge/extension/`, whose
handler forwards to the SAME App-Group socket the real Zodl listens on. Production
Safari support ships INSIDE Zodl (the planned Safari-family target, post-WIP); this
exists only to check Safari UX parity today.

## Test it (≈4 clicks, needs your signing team)
1. Open `Zodl Bridge Safari Dev/Zodl Bridge Safari Dev.xcodeproj` in Xcode.
2. Both targets (app + `…Extension`) → **Signing & Capabilities** → select your team
   (**RLPRR8CPQG**). The extension already carries the App Group `RLPRR8CPQG.zodl.bridge`
   (`dev.entitlements`) — the same group Zodl binds, so the handler reaches the socket.
3. Run the app once (it registers the extension with Safari).
4. Safari → Settings → Extensions → enable **Zodl Bridge Safari Dev**; on the demo page,
   allow it for `localhost`. (If Safari refuses to load it: Develop menu → *Allow
   Unsigned Extensions* — only needed if not team-signed.)
5. Real Zodl running + on Home, serve `bridge/demo` (section 0 = your own address),
   click **Pay 0.001** in Safari → same review card as Chrome.

## Why not ad-hoc / CLI-only
Safari validates extension signatures strictly, and an ad-hoc signature can't claim a
team-registered App Group — so there's no reliable no-Xcode path. The App Group is the
correct mechanism (it's what Zodl already uses); team signing is the only honest way to
exercise it. Same code as the verified Chrome chain — this is a UX-parity check, not a
new capability.
