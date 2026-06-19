# macOS NavigationSplitView Migration — Implementation Plan

> Deprioritized 2026-06-19. Spec: `docs/superpowers/specs/2026-06-19-macos-navigationsplitview-design.md`

**Goal:** Migrate `MacSplitView` from manual `HStack` + `Divider` to native `NavigationSplitView`
(option **B**: native shell, custom dark rail).

**Files:** primarily `secant/Sources/Features/Root/MacSplitView.swift` (macOS-only). Possibly
`zodlmac-internal/zodlmac_internalApp.swift` (window resizability, Phase 5). iOS untouched.

**Reuse, don't rebuild:** the `store.path` → destination `switch`, the `Home` actions (sidebar taps),
and the rail components (`WalletBalancesView`, `SmartBannerView`, account switcher, eye) all carry over
verbatim. Only the *container* + *selection mechanism* change.

## Phases (each ends green `xcodebuild` + visual check + a commit)

### Phase 1 — Swap the container
Replace the body's `HStack { sidebar ; Divider() ; rightPanel }` with
`NavigationSplitView { sidebarColumn } detail: { rightPanel }`. Keep the existing sidebar content +
`rightPanel` switch as-is for now.
→ **Verify:** smooth seam (no Divider), a unified toolbar appears, content renders. The sidebar will
likely show the system material here — fixed in Phase 3.

### Phase 2 — Selection model
Convert the nav list to a `List(selection: $selectedSection)` using the `MacSection` enum as the
selection id. On selection change, send the section's `Home` action (exactly as today's `sidebarRow`
button does). Keep `@State selectedSection` as the source of truth so **Pay vs Swap** stays distinct
(both map to `swapAndPayCoordFlow`).
→ **Verify:** selecting a row highlights it + renders the right detail; Pay and Swap highlight independently.

### Phase 3 — Dark rail (option B)
Override the sidebar column background to Zodl dark: `.scrollContentBackground(.hidden)`,
`.background(Asset.Colors.background.color)`, and `.toolbarBackground` as needed. Keep the account
switcher / balance / sync card / nav rows.
→ **Verify:** rail is dark (brand identity), seam still smooth. If it fights the container badly,
that's the signal to fall back to option A (system sidebar material) — a design call.

### Phase 4 — Toolbar
Confirm the back button renders native top-left (already `.navigation` placement, fixed in commit
`ced8b5ff`). Add any per-section action buttons as `.toolbar { ToolbarItem(placement: .primaryAction) }`
so macOS 26 floats them as glass capsules.
→ **Verify:** back is top-left by the title; action buttons float as glass.

### Phase 5 — Window + polish
Reconsider `FixedWindowConfigurator`: make the window **resizable with a sensible min size** (or keep
fixed) — NavigationSplitView shines with resize/collapse. Tune sidebar min/ideal width (~280). Decide
whether sidebar collapse is allowed.
→ **Verify:** resize/collapse behaves; column widths feel right.

## Verification
Per phase: `xcodebuild -project secant.xcodeproj -scheme zodlmac-internal -destination 'platform=macOS'
build` green + visual check (Lukas). iOS no-regression build at the end.

## Notes
- This supersedes the manual-HStack split from `2026-06-19-macos-split-view.md` (which is shipped +
  polished); start from that working state.
- If Phase 3's dark sidebar fights NavigationSplitView too hard, fall back to option A.
