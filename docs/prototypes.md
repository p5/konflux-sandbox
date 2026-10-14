# Konflux Sandbox architecture prototypes

Use small experiments to settle execution, recovery, source identity, credential, and lifecycle decisions.
Each prototype answers one question and records a decision.
Prototype completion does not establish production readiness.

The [implementation plan](implementation-plan.md) defines the production milestones.

## Priority and decisions

| Prototype | Design question | Decision it informs | When |
| --- | --- | --- | --- |
| P1 Platform and dispatch | Can the extension coordinate sandbox work through ordinary Tekton tasks beside an operator-managed Konflux installation? | Installation dependencies, dispatch contract, and workflow ownership | Start now; informs M0 and M3 |
| P2 Execution recovery | What happens when dispatch, cancellation, result delivery, and cleanup overlap? | Execution states, attempt identity, and retry policy | Before M1 schemas become stable |
| P3 Source and evidence | Can we identify and transport the exact working tree that a check consumes? | Canonical source format, transport, and receipt fields | Before M1 schemas become stable |
| P4 Credential broker | Can an execution use one permitted operation without obtaining the upstream credential? | Broker grant format, execution authentication, and network enforcement | Before M4 |
| P5 Checkpoint semantics | What state survives suspension on the selected runtime? | Runtime capabilities and workspace lifecycle | During M0 evaluation; implementation can follow M5 |
| P6 Investigation workflow | Can the workflow distinguish a reproduced finding, a validated patch, and an inconclusive result? | Investigation states, evidence requirements, and review handoff | Before M6 and M7 schemas become stable |

Start P1, P2, and P3 before broad implementation.
Use P5 early to identify runtime limits that affect later workspace requirements.
P4 and P6 follow when their interfaces become implementation priorities.

## Recorded experiments

The [Kind operator experiment](experiments/001-kind-operator.md) completed P1's existing platform phase.
It recorded a successful native PipelineRun, structured result transport, and an Integration Service schema dependency.
The [prototype findings](prototype-findings.md) index the subsequent executable integration and runtime experiments.
Those experiments include remote dispatch, real Kata execution, canonical OCI source checks, and proposed recovery and broker contracts.

## P1 Platform and dispatch

Start with a disposable Kind cluster and the existing Konflux operator.
Install only the components needed for the experiment.
A complete UI or GitHub App integration is unnecessary for this question.

The first phase observes the existing platform:

1. Create a named cluster with a dedicated kubeconfig.
2. Install Tekton and a documented operator-managed Konflux subset.
3. Run a bounded PipelineRun with a known result.
4. Observe its TaskRuns, logs, completion state, and artifact interfaces.
5. Confirm that extension-specific workflow labels avoid normal build-to-Snapshot processing.

The second phase adds a throwaway dispatcher and execution endpoint.
Use the same request contract from a CLI and a Tekton task.
Run one command, return its result, then cancel another command.
Record which module owns deadlines, retries, and cleanup.
Measure workflow admission, Pod scheduling, dispatch, guest startup, execution, and result delivery separately.
Use those measurements to decide whether a waiting dispatch Pod fits the expected check latency and resource budget.

A mock endpoint can answer dispatch and result questions.
It cannot answer isolation or network enforcement questions.
Use a real VM runtime for those questions after the compatibility milestone identifies its prerequisites.

Docker or Podman can host the Kind nodes.
That configuration does not create a separate guest kernel for each TaskRun.
KVM device availability also does not establish working VM isolation inside Kind.
Record device access, runtime configuration, CNI behavior, and guest identity separately.

Complete the prototype when the supported dispatch shape and required installation dependencies are clear.
Record unsupported step, sidecar, workspace, and result behavior explicitly.

## P2 Execution recovery

Build a small terminal program with an in-memory execution model.
Display the full relevant state after each action.
Keep the state logic separate from the terminal interface.

Provide actions for admission, allocation, dispatch, acknowledgement, completion, cancellation, controller restart, and cleanup failure.
Permit delayed events so cancellation and result delivery can occur in either order.

Drive these cases manually:

- The controller restarts before dispatch acknowledgement.
- The command finishes before the controller records its result.
- Cancellation arrives during source import or command execution.
- A delayed success arrives after cancellation.
- Cleanup fails after a passing check.
- An expired attempt receives a result from an old guest.
- An explicit retry creates a new attempt.

Record whether each case needs a new state, condition, or ownership rule.
An uncertain command outcome must not trigger an implicit duplicate command.
Keep result acceptance separate from cleanup completion.

Complete the prototype when every action has a clear owner and observable outcome.
Use the resulting rules to define the production controller contract.

## P3 Source and evidence

Use a small local Git fixture with tracked changes, selected untracked files, deletions, executable files, and symlinks.
Export the fixture into the proposed canonical manifest and archive.
Import it into a scratch directory or isolated guest.

Answer these questions:

- Do identical selected files produce the same source identity despite archive timestamps?
- Does a changed file mode or symlink target change that identity?
- Can the consumer reconstruct the exact selected source without Git metadata?
- Do ignored and sensitive files remain outside the selected source?
- Can the importer reject path traversal and symlink escape?
- Can a receipt distinguish uploaded source from a verified Git tree?

Use dummy sensitive files in this experiment.
Do not export the user's real credentials or unrelated working directories.

Complete the prototype when the source format and supported filesystem semantics are explicit.
Record the manifest format and receipt identity fields.

## P4 Credential broker

Use a dummy upstream service and a synthetic secret.
The upstream service reports whether the proxy supplied the expected credential.
The guest receives only its execution identity and a restricted grant.

Exercise one allowed request, a denied destination, a cross-execution grant, a redirect, and a revoked grant.
Attempt direct access around the proxy under the selected network profile.
Cancel the execution while a permitted request is pending.

Record the authentication protocol, grant scope, revocation behavior, and remaining disclosure channels.
Distinguish credential exclusion from authorization to send source data to a model.

Complete the prototype when the broker can enforce the selected operation through an actual restricted network path.
An application-level proxy alone does not demonstrate network enforcement.

## P5 Checkpoint semantics

Run a process counter, an interactive shell, a background service, and an open connection inside the selected guest.
Create files in both persistent and temporary storage.
Suspend and restore through the backend's documented lifecycle operations.

Record which state survives:

- Persistent files and temporary files.
- Process identity and process memory.
- Shell state and the interactive terminal.
- Background services and open connections.
- Execution identity, authorization, and broker grants.

Measure cold startup, file-based restart, checkpoint creation, and restoration separately.
Use observed values without promising a production latency target.
If the runtime only recreates a Pod, record that limit and its effect on workspace behavior.

Complete the prototype when the runtime capability matrix distinguishes file persistence from process and VM restoration.
Use that result before promising Chainguard-style suspension behavior.

## P6 Investigation workflow

Use a deliberately vulnerable local fixture and a known patch.
Use scripted actions before introducing a model or a complete discovery harness.

Run the baseline, reproduce the finding in a fresh guest, then validate the same input against the patched fixture.
Add an infrastructure failure and a reproduction timeout.
Compare regression results with the baseline.

Record a finding, candidate, reproduction result, validation result, and review decision.
Keep the evidence private.
Check that an inconclusive result cannot become a successful remediation.
Confirm that one module owns each attempt and publication action.

Complete the prototype when the workflow can represent these outcomes without treating every agent tool call as a PipelineRun.
Use the result to define campaign and investigation resources.

## Prototype execution and capture

Use one local Makefile target for each runnable prototype.
The prototype branch now exposes these targets:

```text
make prototype-konflux
make prototype-recovery
make prototype-artifacts
make prototype-broker
make prototype-runtime
make prototype-vm
make prototype-composed
make prototype-dispatch
make prototype-investigation
make prototype-source-entry
```

Keep prototype code on explicit prototype branches or isolated worktrees.
Mark it as throwaway code.
Do not add repository CI workflows or production dependencies solely for an experiment.

Keep logic state in memory unless persistence is the question.
Use scratch storage for artifacts and dedicated kubeconfigs for live experiments.
Do not modify existing clusters or the default kubeconfig.

Record these fields for every completed experiment:

- The question and bounded workload.
- The source revision and exact dependency versions.
- The command, environment, and resource ownership.
- Observed behavior and concise evidence references.
- The decision, unresolved limits, and affected milestone.
- The cleanup command and any remaining resources.

Retain a completed code prototype on its prototype branch.
Keep the validated architecture decision in the main implementation documents.
Track production conformance separately from prototype observations.
