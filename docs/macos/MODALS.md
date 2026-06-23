# macOS Modals — what to use for what (Zodl Mac)

Companion to `LAYOUT_FOUNDATION.md`. The native modal/overlay menu, a decision guide, **what Zodl
Mac actually uses today (verified in code)**, the macOS gotchas that shaped those choices, and a
use-case table to extend as flows land. Proven hands-on in the sandbox `~/Downloads/testApp` →
**Modals** section (one live button per option).

## Rule #5 — the custom card is the dynamic-content workhorse (DECIDED)
The macOS design language's modal rule (see `DESIGN_LANGUAGE.md`):
- **The custom card overlay** (`.zashiSheet`'s macOS form — OUR SwiftUI, not a native `.sheet`) is the
  primary component for dynamic content: swap quotes, confirmations, dynamic forms. Because it's ours,
  every visual is a knob (size, shape, surface, animation, position).
- **Surface: Liquid Glass** (macOS 26 `glassEffect`), not solid. *(decided — proven + loved in the
  sandbox.)*
- **Scope: GLOBAL by default** — presented over the WHOLE window (the backdrop dims the sidebar too),
  the proper app-modal feel. **It must be presentable from anywhere.** Customizable (size / shape /
  scope) only when a specific flow genuinely needs it.
- **Native modals stay for their specific purposes** — alert, file panel, confirmation dialog, new
  window, inspector (see the decision guide + use-case table below).

**Implementation path (the consequence).** An `.overlay` only covers the view it's attached to, so the
current ~40 feature-level `.zashiSheet` sites center in the **detail pane only** (sidebar stays bright)
— except the account switch (`MacSplitView:127`), which is already whole-window. To satisfy "global +
presentable from anywhere", **hoist card presentation to the `MacSplitView` root**: one global card
presenter holds the state + the window-level overlay; features *request* the card (shared state /
presenter), they do not attach `.zashiSheet` to their own view. This is the modal analog of the
HStack→`NavigationSplitView` migration — mechanical, not a config flag. Sandbox reference: the
"Over whole window" path (`RootSplitView` owns the state, `ModalsView` triggers it → `DemoCardOverlay`).

**Still open (to define):** default card sizing/shape per content, animation, and the exact global
presenter API. We'll keep refining Rule #5 before applying it to the wallet.

## Decision guide — what an iOS sheet *becomes* on Mac
iOS reaches for one bottom sheet for almost everything. On Mac that splits by the task's relationship
to the window:
| The task is… | Use | Native API |
|---|---|---|
| Tied to THIS window, finish-before-continuing | **Sheet** (or a custom card overlay — see below) | `.sheet` + `.presentationSizing(.fitted)` |
| A decision with no real content (error, confirm, destructive) | **Alert** | `.alert` |
| Pick one of ≤3 actions | **Confirmation dialog** | `.confirmationDialog` |
| A small anchored quick pick | **Popover** (careful with lists — see gotchas) | `.popover` |
| Independent, may sit side-by-side | **New window** | `openWindow` + `Window` |
| Contextual detail *beside* content (not a task) | **Inspector** | `.inspector` |
| Save / open a file (export logs, PCZT, backups) | **File panel** | `.fileExporter` / `.fileImporter` |
| App settings | **Settings window** | `Settings` scene (⌘,) |

## What Zodl Mac uses TODAY (verified)
**Key finding: Zodl Mac does NOT use the native `.sheet` for its sheets — both are hand-rolled overlay
cards.** The native sheet was deliberately avoided (see gotchas).

- **`.zashiSheet`** — the dynamic-content sheet (swap quote, confirmations, dynamic cards). On macOS it
  is a **custom centered overlay card**: a dimmed `Rectangle` backdrop (click-outside dismiss), a
  content-hugging card (`maxWidth: 480`, height follows content), an explicit close ✕, and
  `.keyboardShortcut(.cancelAction)` (ESC). NOT a native `.sheet`.
  File: `secant/Sources/UIComponents/Sheets/ZashiSheet.swift`.
- **`.zashiSelectorSheet`** — the searchable selector (swap token, address-book chain). On macOS it is a
  **custom definite-size overlay card** (`460 × [320…600]`) so the inner `List` can fill + scroll; on
  iOS it's a `.popover`. File: `secant/Sources/UIComponents/Sheets/ZashiSelectorSheet.swift`.
- **Alerts** (errors, key decisions) — native `.alert`, same as iOS.

So `.zashiSheet` *is* the key dynamic-content component — but its macOS realization is an **overlay**,
not `.sheet`. That's a deliberate, correct choice given the gotchas below; the native `.sheet` is the
*alternative*, viable for single (non-stacked) standalone content now that `.presentationSizing` exists.

## The macOS gotchas (why native isn't always the answer)
1. **iOS `presentationDetents` collapse a macOS sheet to 0 height.** Never use detents on macOS; size a
   native sheet with `.presentationSizing(.fitted)` (macOS 15+) — this is the macOS-correct content-hug
   and is what makes a native `.sheet` usable here at all.
2. **Only ONE native `.sheet` per view; they don't stack.** Flows that stack sheets can't all be native
   → the overlay card (which stacks freely) is why `ZashiSheet` exists.
3. **A `.popover` collapses a `List`/`ScrollView`** (no intrinsic height) to an unusable bubble → give a
   popover a definite size, or use a card. This is why `ZashiSelectorSheet` is a card on macOS.
4. **`.confirmationDialog` shows at most 3 actions on macOS** (incl. cancel); extras are silently
   dropped. For more choices use a sheet or a menu.

## Use-case mapping (EXTEND this as Zodl Mac flows are decided)
| Flow | iOS | Zodl Mac today | Recommended macOS |
|---|---|---|---|
| Dynamic content (swap quote, confirmations) | `.zashiSheet` | custom overlay card | keep overlay (stacks; full chrome) — or native `.sheet` + `.presentationSizing(.fitted)` if single/non-stacked |
| Searchable selector (token, chain) | `.popover` | custom definite-size overlay card | keep overlay (popover collapses lists) |
| Error / key decision | `.alert` | native `.alert` | native `.alert` ✓ |
| Export logs / files | native share sheet | _(TBD)_ | **file panel** `.fileExporter` / NSSavePanel — save anywhere, share later (more Mac than an in-app share) |
| Big standalone flow | full screen | _(n/a)_ | **new window** `openWindow` (modeless, side-by-side) |
| Detail beside content (tx metadata) | — | — | **inspector** `.inspector` |

## Reference
Live trial of every option: sandbox `~/Downloads/testApp` → **Modals** section (`SectionViews.swift`
`ModalsView`). Layout rules: `LAYOUT_FOUNDATION.md`.
