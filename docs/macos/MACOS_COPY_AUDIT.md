# Zodl Mac — Copy Audit (iOS-derived strings to review for macOS)

The Zodl codebase descends from the iOS wallet, so the shared `Localizable.xcstrings` is written for
iPhone. On macOS some of that copy reads wrong ("keep your phone on an active screen", "tap", "Face ID").
This is a **review list** — internal copy owners decide the final macOS wording; engineering then wires
the approved changes as **platform-conditional strings** (see *How to apply* below).

Audit method: scripted scan of all **1,117** catalog strings (English source) for device/gesture/biometric
terms. Generated 2026-06-25. Re-run the scan after copy lands to confirm nothing new slipped in.

---

## How to apply (engineering note)

macOS must NOT change the iOS copy (Rule #11). For each approved change, add a **macOS-specific key** and
select it `#if os(macOS)` — exactly the precedent already shipped for the support-email OS label
(`supportData.systemVersionItem.versionMac`, commit `2e565889`). New keys need **en + es** (the app ships
Spanish). Example:

```swift
#if os(macOS)
String(localizable: .restoreInfoTip1Mac)   // "Keep Zodl open and your Mac awake."
#else
String(localizable: .restoreInfoTip1)       // "Keep the Zodl app open on an active phone screen."
#endif
```

For the high-volume "tap → click" set, decide a strategy up front (see §2).

---

## 1. Device references — "phone" → Mac  ·  PRIORITY: HIGH (7)

These literally say "phone" / "phone screen" and read wrong on a Mac. The "active phone screen" copy is
about keeping the device awake during restore/sync — on macOS that's *sleep / Energy Saver*, not screen
dimming.

| Key | Current (iOS) | Suggested (macOS) |
|---|---|---|
| `recoveryPhraseDisplay.proceedWarning` | …Don't take screenshots of it or store it on your **phone**! | …or store it on your **computer**! |
| `restoreInfo.tip1` | Keep the Zodl app open on an active **phone screen**. | Keep Zodl open and **your Mac awake**. |
| `restoreInfo.tip2` | To prevent your **phone screen from going dark**, turn off power-saving mode and keep your **phone** plugged in. | To **keep your Mac from sleeping**, adjust **Energy Saver** settings and keep it plugged in. |
| `smartBanner.content.restore.info` | Keep Zodl open on active **phone screen** | Keep Zodl open and **your Mac awake** |
| `smartBanner.help.restore.point1` | Keep the Zodl app open on an active **phone screen**. | Keep Zodl open and **your Mac awake**. |
| `smartBanner.help.restore.point2` | To prevent your **phone screen from going dark**, turn off power-saving mode and keep your **phone** plugged in. | To **keep your Mac from sleeping**, adjust **Energy Saver** settings and keep it plugged in. |
| `smartBanner.help.sync.info` | …Keep the Zodl app open on an active **phone screen** to avoid interruptions. | …Keep Zodl open and **your Mac awake** to avoid interruptions. |

> Note: `restoreInfo.tip1/tip2` and the `smartBanner.help.restore.point1/2` are duplicate sentences — keep
> the macOS wording identical across both so they don't drift.

---

## 2. Gesture verb — "tap" → "click"  ·  PRIORITY: MEDIUM (13)

macOS users **click**, they don't tap. This is a verb swap (`tap`→`click`, `tapping`→`clicking`,
`Tap`→`Click`). It's the largest set, so **decide a strategy first**:
- **(a) Per-string macOS keys** — most faithful, most keys. Recommended for the user-facing flow text.
- **(b) Leave as-is** — "tap" is widely understood; lowest effort, slightly off-brand for Mac.

Copy owners: mark each row keep/change.

| Key | Current (iOS) |
|---|---|
| `coinVote.delegationSigning.instruction` | After you have signed with Keystone, **tap** on the Scan Signature button below. |
| `coinVote.delegationSigning.qrEncodingFailed` | QR encoding failed. **Tap** Cancel and try again. |
| `coinVote.proposalList.reviewSubtitle` | **Tap** on the question to edit any of your answers. After you review your answers, **tap** on Confirm & Submit. |
| `depositFunds.alert.message` | If you've sent or intend to send the funds, **tap** 'I've sent the funds.' Or cancel the swap… |
| `keystone.addHWWallet.step2` | **Tap** the menu icon |
| `keystone.addHWWallet.step3` | **Tap** on Connect Software Wallet |
| `keystone.signWith.desc` | After you have signed with Keystone, **tap** on the Get Signature button below. |
| `reportSwap.msg` | **Tapping** the button below will send details about this swap… |
| `send.addressNotInBook` | Add contact by **tapping** on Address Book icon. |
| `smartBanner.help.shield.info1` | …**Tap** the "Shield" button below to make your transparent funds spendable… |
| `splash.authFaceID` | **Tap** the face icon to use Face ID and unlock it. *(see §3 — not shown on Mac)* |
| `splash.authPasscode` | **Tap** the key icon to enter your passcode and unlock it. |
| `splash.authTouchID` | **Tap** the print icon to use Touch ID and unlock it. *(this IS the Mac biometric string)* |

> `splash.authTouchID` matters most here — it's the one the Mac actually shows when Touch ID is available.
> At minimum change that one to **"Click the print icon to use Touch ID…"**.

---

## 3. Biometric — Face ID vs Touch ID  ·  PRIORITY: LOW / mostly already handled (2)

Macs have **Touch ID**, not Face ID. The app already has a separate Touch ID string
(`splash.authTouchID`) and picks the biometric at runtime, so `splash.authFaceID` is **not displayed on
macOS** — likely no change needed, just confirm the macOS biometric path never falls back to the Face ID
copy.

| Key | Current | Note |
|---|---|---|
| `splash.authFaceID` | Tap the face icon to use Face ID and unlock it. | Not shown on Mac (Mac → `authTouchID`). Verify the runtime selection. |
| `supportData.permissionItem.faceID` | FaceID available | Support-email line. On Mac this should report **Touch ID** — a small code change (like the `…versionMac` precedent), not just copy. |

---

## 4. Generic "device" — LIKELY NO CHANGE (17, listed for completeness)

"device" is platform-neutral and reads fine on a Mac (the Mac *is* a device; "Keystone device" and "from
other devices" are correct). **No change expected** — included so reviewers can confirm. Notable ones:

| Key | Current | Verdict |
|---|---|---|
| `keystone.addHWWallet.connectActive` / `.connectNew` / `.deviceQuestion` / `.scan` | "…device" (the Keystone) | ✅ correct — it's the hardware device |
| `coinVote.delegationSigning.scanSignedPCZTInstruction` | Open your **Keystone device**… | ✅ correct |
| `root.existingWallet.Message` / `root.seedPhrase.differentSeed.message` / `root.serviceUnavailable.Message` | "…on this device" / "your device connection" | ✅ generic — the Mac is "this device" |
| `recoveryPhraseDisplay.warningControl.info` / `restoreWallet.help.phrase` | "…from other devices / any device" | ✅ generic |
| `supportData.deviceModelItem.device` | "Device" (label; value = model) | ✅ label fine. Confirm the **value** reports the Mac model on macOS (code, like the OS-version fix). |
| `sendFeedback.share.notAppleMailInfo` | Your **device** doesn't have an Apple email set up… | ✅ generic (and macOS mail handling is its own gap — see project memory) |
| *(remaining: hardwareWalletExplainer.\*, smartBanner.help.backup.info3, coinVote.store.userError.nullifierAlreadySpent, walletBirthdayHelpDesc)* | "…device" generic / "hardware device" | ✅ no change |

---

## Summary for reviewers

| Category | Count | Action |
|---|---|---|
| **§1 phone → Mac** | 7 | **Change** (clear) |
| **§2 tap → click** | 13 | **Decide strategy**, then change the flagged ones (esp. `authTouchID`) |
| **§3 Face ID** | 2 | Verify runtime path; 1 small code change for support-email biometric line |
| **§4 generic "device"** | 17 | No change expected; confirm |

Nothing iOS-only found for gestures (swipe/pinch/long-press) or home-screen/Control-Center/widget concepts
— the catalog is mostly Mac-safe already. The real work is §1 (+ the §2 strategy call).
