# macOS seed-input hardening — plan & step matrix

**Status:** brainstorming / not yet implemented. This is the menu of options to evaluate
for UX impact before we pick which rungs to build. Branch context: `slipstream-macos`.

## Why this exists

Spendability on macOS means the user types a 24-word recovery phrase into the app. macOS,
unlike iOS, lets an ordinary background process install a keystroke tap (`CGEventTap`) and
read other apps' screens via screen-capture and Accessibility APIs. That is the new attack
surface: **the transmission of the seed into the app.** We cannot fully protect a user
(hardware keyloggers, a rooted machine, a sniffed Bluetooth radio link are all out of any
app's reach) — the goal is to **raise the bar**, one honest step at a time.

Today the seed grid in `RecoverySeedPhraseEntryView` (`RestoreWalletCoordFlowView.swift`) is
24 plain SwiftUI `TextField`s. There is **no** `SecureField`, `NSSecureTextField`, or
`EnableSecureEventInput` anywhere in the repo. Every keystroke is delivered through the normal
event system, visible to any tap. iOS is not similarly exposed (no third-party keystroke taps
without entitlements + sandbox escape), which is why this has only ever bitten on macOS.

## The mechanism — three *separate* things

A common misconception is "secure input = the dots." They are independent:

1. **Keylogger protection** = `EnableSecureEventInput()` (Carbon/HIToolbox). The same switch as
   Terminal's *Secure Keyboard Entry*. When on, keystrokes are flagged secure and **event taps
   in other processes stop receiving them** — whether the field shows dots or real letters.
   It is a **global, session-wide** mode: every `Enable` MUST be paired with a `Disable`, or you
   can wedge keyboard input for *other* apps until logout. The lifecycle is the real work.
2. **On-screen masking** = `NSSecureTextField`'s dots. Purely visual. Stops a shoulder-surfer /
   screen recorder from reading the *field* — but NOT the suggestion chips.
3. **Capture exclusion** = `NSWindow.sharingType = .none`. Removes the entire window's contents
   from the standard screen-capture paths (screenshots, screen sharing, ScreenCaptureKit). One
   move hides fields, suggestions, and which chip was tapped — with no UX cost to the real user.

Because (1), (2), (3) are separable, **we can keep the seed fully visible and still be
keylogger-resistant**, and we can defeat screen-recording without dots. That reshapes the plan.

## Step matrix — all options, ascending UX cost

| Step | What it adds | Blocks | UX impact | Cost / risk |
|---|---|---|---|---|
| **S1 — Secure event input** · `EnableSecureEventInput()` scoped to the seed screen | keystrokes flagged secure | **software keyloggers** (`CGEventTap`), incl. from Bluetooth keyboards | **none** | low code; risk = must balance enable/disable across every exit path or it wedges other apps' keyboard |
| **S2 — Window capture exclusion** · `NSWindow.sharingType = .none` on the seed screen | whole screen excluded from capture | **screen-recording / screenshot malware** seeing the fields, the suggestion chips, AND which chip was tapped | **none** for the real user (a screen-share/recording shows the area blacked-out) | low code; best-effort — standard capture APIs honor it, a kernel/display-stream capture can still bypass (like hardware keyloggers for S1) |
| **S3 — Pasteboard hygiene** · clear clipboard after paste/import; mark our own writes concealed/transient | seed not left on the clipboard | **clipboard-history managers** & other apps reading the pasteboard | minimal (paste still works; clipboard is wiped after) | low |
| **S4 — Field masking + reveal** · dots with an eye toggle | per-character masking of the field | shoulder-surfers; defense-in-depth if S2 is ever unavailable | **medium** — harder to spot a typo across 24 words; reveal toggle mitigates | medium; **half-measure on its own** — suggestion chips still leak the word |
| **S5 — Suggestion privacy** · hide/redact the autocomplete chips | closes the suggestion leak that makes S4 only half-work | screen-leak of candidate words + the chosen word, *when not using S2* | **high** — autocomplete is the single biggest aid for entering 24 words | medium; **largely obviated by S2** (which hides suggestions for free) |
| **S6 — Accessibility hardening** · withhold seed values from the AX tree | AX value not exposed for fields/chips | **Accessibility-API scraping** malware | medium — degrades VoiceOver for seed entry (blind users) | medium; accessibility-regression risk |
| **S7 — In-memory hygiene** · hold words in a zeroing buffer, wipe after derivation | seed not lingering in the heap/swap | **memory / swap / crash-log** forensic exposure | none | high — touches the `words` model + binding plumbing + field editor |

### Reading the matrix

- **S1 + S2 + S3 is the sweet spot ("v1"):** all three are ~**zero UX cost** and together cover
  the three software channels that actually matter for seed entry — keylogger, screen-recording,
  clipboard. Critically, **S2 is the right answer to the suggestions-leak problem**, not dots:
  it hides the chips and the tap wholesale, where S4+S5 (dots + hide-suggestions) would cost real
  usability to achieve less.
- **S4–S7 are defense-in-depth** with rising UX/engineering cost and *falling* marginal value once
  S2 is in place. Worth keeping on the roadmap, not worth blocking v1 on.
- S1 and S2 share one tiny AppKit bridge (an `NSViewRepresentable` attached only on macOS), so
  they're naturally built together.

## v1 — implemented (macOS), builds green

S1 + S2 + S3 shipped together. iOS is untouched (Rule #11): the modifier is a no-op there and S3 is
`#if os(macOS)`-gated.

**S1 + S2 — `secant/Sources/UIComponents/SeedScreenSecurityGuard.swift`** (new). A `.seedScreenSecurityGuard()`
View modifier backed by an `NSViewRepresentable` (the same `viewDidMoveToWindow` + walk-the-hierarchy
pattern as `MacSplitView.FixedSidebarWidth`), attached to `RecoverySeedPhraseEntryView`. While that
screen is on-screen it reconciles to a single desired state, applied as **balanced deltas**:

- secure event input ON iff on-screen **and** app frontmost (released on `didResignActive`, re-taken
  on `didBecomeActive` — never held while another app is frontmost);
- `window.sharingType = .none` while on-screen, with the window's **previous** sharing type captured
  and **restored** on exit (the app window outlives the seed screen — it later shows the wallet — so
  leaving it excluded would block all future screen-sharing). Teardown runs from
  `viewDidMoveToWindow(nil)` and `dismantleNSView`, both main-actor; no `deinit` backstop (process exit
  releases secure input anyway). Every `EnableSecureEventInput()` is balanced by exactly one `Disable`.

**S3 — `RestoreWalletCoordFlowCoordinator.commitRestore`.** Finding from the code: the app **never
copies the seed to the clipboard** (no copy affordance on the recovery-phrase display) and has **no
whole-phrase paste** in production (`debugPasteSeed` is `#if DEBUG`), so "mark our writes concealed" is
already satisfied by omission. The real exposure is the user's **own** clipboard holding the full
phrase (copied from a password manager). So on a successful restore, if the system clipboard still holds
the just-restored phrase (exact whitespace/case-normalized match — so we **only** ever clear the seed,
never unrelated content), we wipe it. macOS-only (reading `UIPasteboard` on iOS would trip the system
paste banner, and iOS's clipboard is more sandboxed).

> Roadmap S4–S7 below remain unbuilt — kept for later evaluation.

## What NONE of this stops (stated honestly)

Hardware keyloggers, a USB/firmware implant, kernel- or root-level malware, and interception of
the Bluetooth radio link itself are all below the layer an app controls. These steps defeat the
realistic **software** attacker on an otherwise-healthy Mac; they are not a guarantee against a
fully-compromised machine. That's the honest framing to keep.

## iOS

Out of scope for now (macOS-only first). iOS doesn't permit third-party keystroke taps, so S1 has
no iOS analog; screenshot/record defense there would be the `isSecureTextEntry` overlay trick — a
separate, later conversation if ever wanted.
