# Dispatch and execution recovery

Date: 14 October 2026.

## Questions

Can a local client and Tekton task use the same asynchronous execution interface?
Which state rules prevent duplicate dispatch and stale result acceptance?
How does PipelineRun cancellation reach an external execution?

## Executed prototypes

```sh
make prototype-recovery
make prototype-recovery-interactive
make prototype-dispatch
```

The recorded recovery scenarios ran automatically.
The interactive target exposes the same state model for manual exploration.
The dispatch target built a local image, loaded it into Kind, and deployed an execution endpoint.
It published no external image.

## Recovery model

Seven scenarios completed:

- Normal execution and cleanup.
- Cancellation before dispatch.
- Late success after cancellation.
- Controller restart during uncertain dispatch.
- Cleanup failure after a passing check.
- Result delivery from an earlier attempt.
- Deadline expiry followed by a late result.

The model separates the check outcome from cleanup.
An uncertain dispatch records Unknown and does not repeat the command automatically.
An explicit retry starts another attempt after cleanup.
The new attempt rejects an earlier attempt's result.

This is a proposed extension contract.
It does not reproduce Konflux controller internals or prove durable recovery.
Production persistence and request deduplication need additional implementation.

## Actual dispatch transport

The local client executed real commands through an HTTP endpoint in namespace dispatch-prototype.
The endpoint verified the submitted script digest.
Repeated submission with the same request identity returned the existing execution.
Different input under that identity returned HTTP 409.
Missing identity returned HTTP 403.
An incorrect digest returned HTTP 400.

The endpoint produced these observed outcomes:

| Command case | Outcome | Cleanup scope |
| --- | --- | --- |
| Passing command | Passed | Process group and files |
| Nonzero exit | CheckFailed | Process group and files |
| Explicit cancellation | Cancelled | Process group and files |
| Deadline expiry | TimedOut | Process group and files |
| Passing parent with background child | Passed; child no longer runs | Process group and files |

The endpoint kills its command process group after completion and removes the scratch directory.
The background-child scenario accepts a removed process or an exited zombie state.
It rejects a live child.
The receipt explicitly names cleanupScope as process-group-and-files.

A command can create a separate process session.
This prototype does not establish complete guest destruction or protection against hostile code.
The runtime experiment independently demonstrates Sandbox and VM deletion.

## Tekton integration

A real PipelineRun submitted a command, polled its execution, and exposed the structured result as a Tekton result.
The dispatcher used the same HTTP interface as the local client.
The passing run returned Passed and cleanupComplete=true.

A second PipelineRun submitted a long-running command.
The prototype waited until that remote execution reported Running, then set the PipelineRun status to Cancelled.
The task's signal and exit handlers called DELETE on the remote execution.
The endpoint reported Cancelled and cleanupComplete=true before its independent deadline expired.

This verifies the tested termination path.
A dispatcher Pod crash or node failure can bypass its exit handler.
Production cancellation therefore needs an external owner that observes workflow state, plus a deadline enforced by the execution supervisor.
The task's exit handler is an additional cleanup path.

## Limits and decisions

The endpoint uses synthetic authentication, plaintext cluster transport, and an in-memory request map.
Its commands share the endpoint's container and kernel.
It must remain throwaway prototype code.

The endpoint proves interface and result mechanics.
The Kata experiment proves actual VM execution through a separate path.
Neither result alone establishes the complete production execution contract.

Decisions:

- Keep request identity immutable after admission.
- Record an explicit identity for each attempt.
- Preserve Unknown, Cancelled, TimedOut, and infrastructure outcomes.
- Track cleanup independently from a passing check.
- Enforce deadlines outside the dispatcher task.
- Keep authoritative cancellation outside the task that can disappear.
- Permit ordinary Tekton task dispatch through a small versioned interface.

Evidence remains under `.prototype-results/recovery.log` and `.prototype-results/dispatch/`.
Rerunning the Makefile targets regenerates those captures.
