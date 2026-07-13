# Zodl for macOS — Beta 4 (Release Candidate 1)

**Version 3.7.1 (build 5)** · July 4, 2026 · tag `beta4-rc1` · slipstream engine **v0.3.6** (SDK tag `zodl-beta4-rc1`)

## The headline

**Slipstream is now the default sync engine on macOS** — this is the first build ever to ship
with it on out of the box. What that means for you: restores measured in minutes, a balance
and Activity list that never over-promise while a restore is running, and a wallet that keeps
itself consistent no matter what you do to it mid-sync. iOS builds are untouched — the flag
stays off there.

If all six gates below pass on this exact build, Beta 4 ships as Release Candidate 1.

## What's new since Beta 3

### Sync engine — the lifecycle hardening wave (v0.3.6)

- **Do anything, anytime.** Connect a Keystone, disconnect it, delete an account, rewind,
  or import a wallet *while a restore or sync is running* — every wallet mutation is now
  serialized with the sync pass. The whole "error → only an app restart fixes it" class is
  gone.
- **Self-healing session.** If a sync pass does fail on something non-transient, the engine
  revives itself on a backoff (15 s → 5 min). You should never need to relaunch to resume.
- **Interrupted restores self-repair.** Leftover scan work from a removed account is pruned
  every time the wallet opens, so a disconnect-during-restore can't leave the engine chasing
  a ghost account.
- **"Database is locked" eliminated.** In-flight background writes now drain fully before
  any account mutation touches the wallet file.
- The `[ZRUST0096]` polling-tick failure on imported/Keystone wallets is fixed.
- Mined transactions no longer transiently vanish from Activity after sending during a
  restore.
- Coverage is tracked in a 42-scenario lifecycle matrix
  (`ZcashLightClientKit/docs/slipstream/SCENARIO_MATRIX.md`) — zero red rows.

### Keystone

- The PCZT sign flow is fully wired on macOS, shielding included — and its teardown is
  fixed, so rejecting a shield no longer leaves a stale banner behind.
- "Keep Zodl open" screen: **OK now shows a spinner and disables** while the import kicks
  off — no more clicking twice into what felt like a dead button.
- The camera scanner is no longer width-capped inside the shielding sign flow.
- The shield-funds banner refreshes after the sign flow closes, and dismisses on device
  disconnect.

### Swap / Pay

- **Amount input rebuilt** on a native field: placeholder hides on focus, caret sits on the
  correct side, baseline no longer jumps.
- **Stuck-pending fixed**: every terminal Near status is now mapped in both parser branches,
  and the auto-status loop resurrects itself after a dropped network request.
- Custom slippage: the "%" is readable, the prompt renders under the caret, and the warning
  box keeps its width.

### macOS app polish

- Animated sphinx landing for first launch.
- Both startup pops are gone (window centering + sidebar width).
- Wallet reset now works on upgraded keychain entries.
- Window menu can reopen the main window, and "About Zodl" is back (App Review Guideline 4).
- Activity filters + search survive switching sections.
- One consistent selection color in the sidebar; hide-eye toggle next to the balance;
  spinners are the right size and color on every CTA, light or dark.

## What to hammer on (the six gates)

The formal script is `ZcashLightClientKit/docs/slipstream/BETA4_RC1_GATE.md`. In tester
words:

1. **Fresh restore**, start to finish — balance must never show more than is real.
2. **Connect a Keystone during that restore**; then disconnect it mid-restore; then add it
   again. Errors may flash, but sync must continue by itself.
3. **Delete the Keystone account mid-sync.**
4. **Kill the app mid-restore, relaunch** — it must resume where it left off, with zero
   dialogs.
5. **Rewind / resync** from Settings.
6. **Wipe → restore → import a Keystone while restoring** — then verify every Keystone
   amount is present and correct.

Rule of thumb: anything that requires an app restart to recover is a P0 — capture the log
and report it.

## Known items (not blockers)

- The first Add-HW-wallet flow shows no "Restoring" state yet (B4-18).
- Transparent-funds edge cases are scheduled for a later wave (v3).
