//
//  DelegationRecoveryFlag.swift
//  zodl
//
//  The dependency between the two voting flags, stated where the compiler can
//  enforce it.
//
//  `RECOVERY_VOTING_ENABLED` gates everything that exists only because some
//  devices were wiped: the carver, the launch-time recovery, and the escrow it
//  writes to. It is DELIBERATELY separable, because that work is finite. Once
//  every affected device has been recovered, removing the flag from the build
//  configurations turns the whole mechanism off in one edit, and deleting the
//  guarded files afterwards is a mechanical follow-up rather than an
//  archaeology exercise.
//
//  What is NOT behind it: the error messages. A voter can hit an incomplete
//  delegation setup for reasons that have nothing to do with the wipe, so
//  `DelegationDiagnosis` stays under `VOTING_ENABLED`. It simply loses the one
//  state that only recovery can produce -- see `escrowHoldsRecoveredSecrets`.
//
//  The dependency is enforced twice over: the build configurations only ever
//  add `RECOVERY_VOTING_ENABLED` alongside `VOTING_ENABLED`, and the check
//  below fails the build for anyone who sets it by hand without the other.
//

#if RECOVERY_VOTING_ENABLED && !VOTING_ENABLED
#error("RECOVERY_VOTING_ENABLED requires VOTING_ENABLED: the recovery code is built on the voting types.")
#endif
