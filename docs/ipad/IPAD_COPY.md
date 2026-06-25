# Zodl iPad — Copy Audit (Phase iP-6)

iPad runs the iOS copy, which is **mostly correct already**: iPad is touch, so "tap" is right (no
tap→click); iPad has Face ID / Touch ID, so the biometric copy is fine. The **only** copy that reads wrong
on iPad is the same device-reference set the Mac audit flagged — "phone" → iPad. So compared to
`MACOS_COPY_AUDIT.md`: **§1 applies (as "iPad"), and §2 (tap→click), §3 (Face ID), §4 (device) do NOT.**

**Engineering note.** The macOS approach (platform-conditional `#if os(macOS)` keys) does NOT help here —
iPad is iOS. Two options:
- **Runtime idiom check** — pick the iPad wording when `UIDevice.current.userInterfaceIdiom == .pad`.
- **Generic wording** (recommended) — one string correct on iPhone AND iPad ("your device" / "your
  screen"), no branch, lowest effort. macOS still wants the explicit "Mac" wording from `MACOS_COPY_AUDIT.md`
  §1 (it already uses platform-conditional keys).

| Key | Current (iPhone) | iPad wording | Generic (iPhone + iPad) — recommended |
|---|---|---|---|
| `recoveryPhraseDisplay.proceedWarning` | …store it on your **phone**! | …on your **iPad**! | …on your **device**! |
| `restoreInfo.tip1` | …on an active **phone screen**. | …active **iPad screen**. | …active **screen**. |
| `restoreInfo.tip2` | …**phone screen** from going dark… **phone** plugged in. | …**iPad screen**… **iPad** plugged in. | …**screen** from going dark… **device** plugged in. |
| `smartBanner.content.restore.info` | …active **phone screen** | …active **iPad screen** | …active **screen** |
| `smartBanner.help.restore.point1` | …on an active **phone screen**. | …active **iPad screen**. | …active **screen**. |
| `smartBanner.help.restore.point2` | …**phone screen**… **phone** plugged in. | …**iPad screen**… **iPad** plugged in. | …**screen**… **device** plugged in. |
| `smartBanner.help.sync.info` | …active **phone screen**… | …active **iPad screen**… | …active **screen**… |

**Recommendation for review:** adopt the **generic column** — it fixes iPhone+iPad in one string and needs
no idiom branch (the restore/sync "active screen" guidance is true on every device). Hand to internal copy
owners alongside `MACOS_COPY_AUDIT.md`.

## Remaining iP-6 (needs iPad visual testing — your pass)
- Per-section sweep on iPad regular: toolbar items, back buttons, onboarding hero full-bleed (#8a), scan
  (#9), modal sheets — the regression classes from `docs/macos/DESIGN_LANGUAGE.md` should hold on iPad too.
- Tune `Design.IPad` (`sidebarWidth` 320, `viewCapWidth` 640, `maxButtonWidth` 340) against real iPad sizes.
- Decide sidebar-collapse UX (native iPad lets the user collapse it; confirm #9/#10 full-screen still works
  alongside user-driven collapse).
