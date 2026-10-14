# Experiment 013: durable execution lifecycle

## Question

Can Kubernetes retain one execution attempt across controller crashes and dispose of its real Kata guest?
Can the same request model support finite commands and held sessions?

## Method

Run `make -C prototypes/durable run`.
The suite uses the dedicated `kind-konflux-sandbox-vm-prototype` cluster.
It uses `kata-prototype` and the preloaded `konflux-sandbox-runtime:prototype` image.
Kubernetes clients use v0.37.1.
The module uses Go 1.26.

The prototype defines the namespaced `foundation.sandbox.p5.dev/v1alpha1` `Execution` CRD.
The controller uses Kubernetes status, immutable request fields, owner references, and a finalizer.
A Kubernetes Lease selects one active controller.
A Pod runs one attempt with `restartPolicy: Never`.
The Pod receives no Kubernetes token or host mount.

The source and profile digests are synthetic input identities.
The owner ID is a caller claim.
This experiment does not prove source import, profile enforcement, or caller authentication.
The Kata guest and the controller actions are real.

## Results

The standalone serialized `make -C prototypes/durable run` passed with exit code `0` on 2026-10-14.
It used the frozen source and all scenarios below.
The suite captures source and binary SHA256 values beside its results.

An earlier extended run failed during the foreign-Pod deletion watch under heavy host load.
The API timed out and the controller lost its short Lease renewal deadline.
The Pod was absent after the timeout.
The serialized run used the explicit guest ServiceAccount, conservative Lease, and deletion polling described below.

The suite captures inputs, Kubernetes objects, controller logs, guest logs, and runtime observations.
The latest files stay in `.prototype-results/durable/`.
Aggregate replay replaces those captures; the timings below describe the earlier standalone run.
The assertions fail the Make target on a mismatch.

| Scenario | Observed result |
| --- | --- |
| Crash before dispatch intent | Restart creates the first child and records `Succeeded` |
| Crash after durable intent, before POST | Restart records `UnknownOutcome`; no child appears |
| Delete unknown request without allocation binding | `cleanupUnverified=true` holds the finalizer |
| Crash after successful POST, before child UID status | Restart adopts the exact existing Pod UID |
| External cancellation | `spec.cancel=true` stops the owned guest and records `Cancelled` |
| Child disappears before recovery | Restart records `UnknownOutcome`; no replacement child appears |
| Trusted lost-child recovery | Independent UID/SID capture restores the binding; disposal checks complete |
| Controller outage at deadline | Kubelet records Pod `Failed` with `DeadlineExceeded` |
| Controller outage with active cancellation | Separate watchdog observes `spec.cancel` and deletes the exact child |
| Delayed Pod start and controller outage | Watchdog enforces the absolute deadline before native ADS expires |
| Owner deletion | Finalizer holds deletion until the owned Pod and own VM disappear |
| Foreign child at the deterministic name | Controller rejects ownership and leaves the foreign Pod unchanged |
| Immutable request changes | Kubernetes rejects changes to all nine immutable fields |
| Cancellation withdrawal | Kubernetes rejects `cancel=true` to `cancel=false` |
| Explicit new attempt | New object UID and `a2` produce a different child identity |

The guest reported kernel `6.18.35`.
The node reported kernel `7.2.9-201.fc44.x86_64`.
Each live observation found the guest's CRI sandbox and its matching QEMU PID.
Each completed disposal observation found no ready sandbox or matching QEMU PID.
The observer selects the namespace, child name, Pod UID, and recorded runtime ID.
Other agents' guests do not affect this check.

## Important failure window

The controller persists dispatch intent before it creates the child.
This order prevents the controller from repeating an uncertain dispatch.
It can also stop an attempt that never started.
The result is deliberately conservative.

The Pod can disappear before the controller records its UID and runtime ID.
The observer first queries retained CRI metadata by the deterministic child name and Pod UID where available.
If that metadata also disappears, the controller cannot associate an orphan QEMU process with this attempt.
It records `cleanupUnverified=true` and keeps the finalizer.
A missing Pod alone never completes disposal for a committed dispatch.

The lost-child scenario uses an independent trusted observer before deletion.
The suite removes only that stopped guest's CRI metadata to reproduce the missing binding.
The administrative recovery command restores that recorded UID/SID association.
The controller then checks the specific runtime allocation before it clears the finalizer.
This command does not validate a signed provider receipt.

The intent-only scenario has no recorded allocation identity.
Its deletion remains pending after the suite.
A production supervisor must record the allocation binding before untrusted code starts.
It must support durable lookup by execution UID and attempt ID.

## Deadline and cancellation limits

The submitting CLI exits before the controller handles cancellation.
Kubernetes retains the cancellation request.
A separate watchdog process reads cancellation, deletion, and absolute deadlines.
It checks the owner UID before it deletes the child with a UID precondition.
It has no dispatch or status-write path.

The suite stops the lifecycle controller before it requests cancellation.
The watchdog deletes the guest without the lifecycle controller.
Another scenario delays scheduling for ten seconds.
It then stops the lifecycle controller while the guest runs.
The watchdog deletes the child within five seconds after the absolute deadline.
The assertion also requires deletion at least seven seconds before native ADS expiry.
The standalone absolute deadline was `2026-10-14T12:14:17Z`.
The watchdog deleted the child at `2026-10-14T12:14:18.01612418Z`.
The delay was 1.016 seconds.
Native ADS expired at `2026-10-14T12:14:28Z`.

The native deadline scenario stops the lifecycle controller without a watchdog.
Kubelet stops that guest through `activeDeadlineSeconds`.

`activeDeadlineSeconds` starts from Pod start time.
A scheduling or startup delay can extend execution beyond the requested absolute deadline during a controller outage.
The independent watchdog closes this gap while the Kubernetes API is available.
Cancellation and absolute deadlines still need that API and an available watchdog.
The suite does not interrupt the shared API server.
A production runtime supervisor must enforce the deadline and cancellation without the API server.
Native ADS supplies a second bound, with the Pod-start clock limit above.

## Architectural decision

Keep a small execution request API above the runtime provider.
Make attempt identity, immutable input identities, cancellation, deadline, and disposal state part of that API.
Do not put request ownership in an interactive caller process.
Do not repeat an uncertain command automatically.

Native Tekton remains useful for finite task graphs, results, and Konflux integration.
Its [PipelineRun API](https://github.com/tektoncd/pipeline/blob/90b2235c66fb02d98e51c148a66725c537c805d6/pkg/apis/pipeline/v1/pipelinerun_types.go#L260) already has cancellation, timeouts, and results.
A single direct Pod was enough for this one-attempt prototype.
A Job retry adds unwanted command replay unless its retry policy disables replacement.
A PipelineRun alone does not provide the tested common owner/session API or the supervisor allocation receipt.
Existing Agent Sandbox lifecycle APIs can supply session allocation beneath this request API.
Its [Sandbox lifecycle](https://github.com/kubernetes-sigs/agent-sandbox/blob/5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1/api/v1beta1/sandbox_types.go#L326) already has `shutdownTime`.
That controller already supplies an absolute lifetime separate from its command client.
Reuse or extend that path when Agent Sandbox owns allocation.
Its Kubernetes dependency leaves the runtime-local outage requirement unchanged.
Its [command client](https://github.com/kubernetes-sigs/agent-sandbox/blob/5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1/clients/go/sandbox/commands.go#L52) disables retries for non-idempotent execution by default.

Both `finite` and `session` modes use the same bounded allocation here.
The session case holds a command alive until cancellation or deadline.
It does not implement reconnect, multiple commands, or interactive command acknowledgements.

The Lease does not prove distributed fencing during arbitrary network failures.
The suite does not prove exactly-once external side effects.
The provider must retain allocation identity, command acknowledgement, and disposal evidence for production recovery.

## Remaining state

No prototype Pod or host controller remains after a successful suite.
The namespace retains terminal records and intent-only requests with pending deletion.
The suite stops both host processes.
The cluster, CRD, and namespace remain available for composition.
The kubeconfig stays outside the repository.

## Code references

- [Execution schema](../../prototypes/durable/crd.yaml) fixes the request and attempt fields.
- [Lifecycle controller](../../prototypes/durable/main.go) persists dispatch intent, adopts children, and gates disposal.
- [Child definition](../../prototypes/durable/child.go) fixes RuntimeClass, resource limits, token mounts, and native timeout.
- [Watchdog](../../prototypes/durable/watchdog.go) supplies independent cancellation and absolute deadlines.
- [Executable scenarios](../../prototypes/durable/run.sh) contain the failure injection and strict assertions.

The host processes use the private administrative prototype kubeconfig.
This experiment does not deploy production controller RBAC or prove tenant isolation.
The current Lease uses 15-second expiry, 10-second renewal, and 2-second retry intervals.
The installer creates a dedicated guest ServiceAccount with token mounts disabled.
Deletion assertions poll successful API reads instead of a long watch stream.
These changes reduce local prototype races; they do not remove API availability requirements.

## Follow-up: runtime-local guardian

Run `make -C prototypes/durable runtime-guardian`.
The target uses `foundation-guardian-prototype` and one guest at a time.
It uses the same Kata image and a 512Mi container limit.

The harness captures the running Pod UID, CRI sandbox ID, and expiry time.
It then stops its own lifecycle controller.
A separate shell guardian receives only that trusted binding.
The guardian has no Kubernetes client or kubeconfig.
It reads the node's CRI and process inventory through Docker.
It rechecks the exact Pod UID and SID before `crictl stopp`.
The stop affects only that allocation.

The API server remains available.
The shared kubelet and Agent Sandbox controller remain active.
This experiment simulates unavailable fixture clients.
It does not partition or stop the shared API server.

The initial guardian run passed its functional assertions.
Its integer-second observation timer needed correction.
The final target uses a nanosecond clock and a final observation after the deadline.
It asserts an observation duration of at least 30 seconds.
The root aggregate replayed that final revision successfully.
Its three observation durations were 30.324, 30.201, and 30.725 seconds.
The final restartable case again observed a new SID and repeated entrypoint under one unchanged Pod UID.
The initial functional run stays in `.prototype-results/durable-guardian-initial/`.
The exact IDs and times below refer to that preserved run.

| Allocation | Expiry | Initial VM | Replacement | Command replay |
| --- | --- | --- | --- | --- |
| Durable Pod, `Never` | Absolute deadline | Stopped | None observed | None observed |
| Durable Pod, `Never` | Earlier allocation lease | Stopped | None observed | None observed |
| Actual Agent Sandbox, `Always` | Earlier allocation lease | Stopped | New SID and QEMU process | Observed |

The restartable case retained Pod UID `f2c59b69-0e60-4b2b-94a8-952a9a11792f`.
Its allocation lease expired at `2026-10-14T12:36:33Z`.
The guardian stopped SID `2a49bcaea2ab...` at `12:36:33.129Z`.
The old VM disappeared.
A replacement SID `0c339e28b96b...` then had QEMU PID `105139`.
The Pod UID did not change.

The initial command ran in container `570b6a057472...`.
Container `13cee740669d...` then failed with `StartError` and never started.
That failed start is not command replay evidence.
Container `ced8ad18b6f9...` started at `12:36:45.312434913Z`.
It printed `EXECUTION_START=guardian-a1` again.
The Pod reported `restartCount=2`.
These records distinguish a replacement VM, a failed container start, and a repeated command.
The repeated command is the synthetic Pod entrypoint workload.
The fixture does not invoke the sandboxd `Run` or `Start` API.
It does not show automatic replay of a command sent through those APIs.

The files include full IDs, start times, command markers, runtime PIDs, and Kubernetes objects.
They stay in `.prototype-results/durable-guardian/`.
The guardian records `UnknownRuntimeOutcome`, `disposalProven=false`, and `replayPrevented=false`.
It never treats the old SID's removal as terminal request disposal.

After observation, the harness restores its API clients.
It cancels each durable request and suspends the Agent Sandbox with an owner UID check.
It then checks every observed SID for VM removal.
The completed run left no Pod or guardian process.
The suspended Sandbox and completed Execution records remain for inspection.

### Required runtime contract

A production supervisor must reject a new allocation after its request expires.
A stop call alone does not supply that gate for restartable sessions.
The supervisor must bind each allowed allocation to a fresh request and attempt authority.
It must persist that binding before untrusted execution starts.

Pod UID alone is not enough for an active identity binding.
A new VM and repeated command retained the same Pod UID in this experiment.
Bind identity authority to the provider allocation ID or generation and its expiry.
Do not let a replacement allocation reuse an expired enrollment or execution authority.
This experiment does not exercise mTLS enrollment.
It identifies the runtime identity change that enrollment must check.

The `Never` results show no replay during this bounded observation.
They do not prove replay prevention for every crash or restart state.
A production implementation needs a durable runtime admission gate and explicit allocation lookup.

See [runtime guardian](../../prototypes/durable/runtime-guardian.sh) and [executable harness](../../prototypes/durable/guardian-run.sh).
The Makefile serializes its targets through `.NOTPARALLEL`.
The failure trap deletes only a captured Pod UID and suspends the exact Sandbox owner when present.
If API cleanup fails, the results directory contains recovery instructions.
