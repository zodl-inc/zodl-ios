# macOS NavigationSplitView Migration — Design

**Status:** Designed, not started (deprioritized 2026-06-19). The current macOS split (`MacSplitView`,
a manual HStack) is shipped + polished; this is the upgrade to a native Messages/Mail-style shell.

**Goal:** Replace the manual `HStack { sidebar · Divider() · content }` in `MacSplitView` with SwiftUI's
native **`NavigationSplitView`**, so the macOS app gets the native split look for free: a smooth seam
(no hard `Divider`), a **unified toolbar** spanning both columns, native top-left back placement,
sidebar collapse/resize, and intentional **floating liquid-glass toolbar buttons** (macOS 26).

**Motivation:** Our manual HStack sits *outside* the native split container, which is the root cause of
the recurring toolbar / glass-bubble friction (screenTitle, zashiTitle, back-button placement) and the
hard divider. `NavigationSplitView` owns the toolbar + seam natively, so those stop being fights.

## Chosen approach — B: native shell, custom rail
Use `NavigationSplitView` for the **structure** (unified toolbar, soft seam, collapse, floating glass
buttons) but **override the sidebar background** to keep Zodl's dark custom rail (account switcher,
balance, purple sync card, nav list).

Rejected alternative **A (full-native):** embrace the system translucent sidebar material — most
Messages-like + least code, but the rail loses Zodl's dark brand identity. Revisit if the dark rail
fights the container too hard (see Risk 1).

## Architecture mapping (from today's `MacSplitView`)
| Today (manual HStack) | NavigationSplitView |
|---|---|
| `HStack { sidebar.frame(260) · Divider() · rightPanel }` | `NavigationSplitView { sidebar } detail: { rightPanel }` |
| `@State selectedSection` drives the highlight; taps send `Home` actions that set `store.path` | sidebar `List(selection:)` bound to `selectedSection`; selection still sends the same `Home` actions → `store.path` |
| right panel = `switch store.path { … destination views }` | same switch, now in the `detail:` column |
| left rail = custom VStack (account/balance/sync/nav) | same components, now in the `sidebar` column, with a background override to stay dark |

**Key:** the `store.path` → destination logic and the `Home` actions are **unchanged**. Only the
*container* changes (HStack → NavigationSplitView) and selection becomes a `List(selection:)` binding
instead of manual `@State` + buttons.

## Components
- **Sidebar column:** account switcher + `WalletBalancesView` + `SmartBannerView` + a
  `List(selection: $selectedSection)` of nav rows (Activity/Receive/Send/Pay/Swap/More). Background
  overridden to Zodl dark (option B) via `.scrollContentBackground(.hidden)` +
  `.background(Asset.Colors.background.color)` + `.toolbarBackground` as needed.
- **Detail column:** the existing `rightPanel` switch on `store.path`, each section's CoordFlow
  NavigationStack nested inside. Default = Activity (`transactionsCoordFlow`), as today.
- **Toolbar (unified):** back button via the existing `zashiBack` (already fixed to native top-left
  `.navigation`) + per-section action buttons as `.toolbar { ToolbarItem(placement: .primaryAction) }`
  → floating glass on macOS 26.

## Out of scope / unaffected
- **Single-view flows** (onboarding/restore/welcome) are *separate RootView destinations*, not the
  split — they keep `macOSSingleViewLayout()` and are unaffected.
- iOS — all changes are `#if os(macOS)` in `MacSplitView`; iOS untouched.

## Risks / open questions
1. **Dark rail vs sidebar material** — NavigationSplitView's sidebar wants the system material; forcing
   it dark may need `.toolbarBackground(.hidden)` + background overrides and could look slightly off vs
   a true custom panel. This is the A-vs-B crux; **B chosen, revisit if it fights**.
2. **Selection model** — moving from manual `@State selectedSection` + buttons to `List(selection:)`
   must preserve Pay-vs-Swap (both → `swapAndPayCoordFlow`); keep the local-selection approach (the
   `MacSection` enum is the selection, **not** `store.path`).
3. **Column widths / collapse** — set a sensible sidebar min/ideal width (~280) and decide whether
   collapse is allowed (Messages allows it).
4. **macOS 26 glass** — confirm the floating toolbar buttons render as intended (they should, natively).
5. **Window sizing** — the current fixed 1120×760 non-resizable window may want to become **resizable
   with a min size** (NavigationSplitView shines with resize/collapse). Reconsider `FixedWindowConfigurator`.
