# Execution recovery prototype

Question: which state and attempt rules prevent duplicate dispatch, stale results, and unsafe retries?

This throwaway program explores a proposed extension contract.
It does not reproduce Konflux controller internals.

Run all recorded scenarios with `make prototype-recovery` from the repository root.
Use `make prototype-recovery-interactive` to drive the state manually.

The model records check outcome separately from cleanup.
An uncertain dispatch produces an unknown outcome and no automatic retry.
An explicit retry starts a new attempt after cleanup.
