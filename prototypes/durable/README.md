# Durable execution prototype

This prototype uses a real Kubernetes API and real Kata guests.
It evaluates request state, crash recovery, cancellation, and disposal.
It does not implement a production service.

## Run

```sh
make -C prototypes/durable run
```

The runtime prototype must first install the dedicated VM cluster and image.
The guard checks the exact context, loopback endpoint, Docker node, and RuntimeClass.
The suite uses one guest at a time, with a 512Mi container limit.
Captured state stays in `.prototype-results/durable/`.

## Consumer contract

Install the CRD and create an owned namespace:

```sh
make -C prototypes/durable install DURABLE_NAMESPACE=foundation-composed-prototype
make -C prototypes/durable controller DURABLE_NAMESPACE=foundation-composed-prototype
make -C prototypes/durable watchdog DURABLE_NAMESPACE=foundation-composed-prototype
```

Create `foundation.sandbox.p5.dev/v1alpha1`, kind `Execution`.
The resource name identifies the request within its namespace.
The Kubernetes UID identifies this request incarnation.
`spec.attemptID` identifies its single attempt.
The child name includes the full execution UID and attempt ID.
A new attempt requires a new Kubernetes object.

| Field | Contract |
| --- | --- |
| `spec.ownerID` | Immutable owner claim; this prototype does not authenticate the caller |
| `spec.sourceDigest` | Immutable requested source identity; no source import proof |
| `spec.profileDigest` | Immutable requested profile identity; no profile admission proof |
| `spec.image` | Immutable preloaded image; status records the actual image ID |
| `spec.command` | Immutable command array |
| `spec.env` | Immutable public string map; never put secrets here |
| `spec.deadline` | Immutable absolute deadline |
| `spec.mode` | Immutable `finite` or `session`; both use one bounded Pod |
| `spec.cancel` | One-way cancellation request; `true` cannot return to `false` |
| `status.phase` | `Allocating`, `DispatchCommitted`, `Starting`, `Running`, or a terminal phase |
| `status.childUID` | Exact owned Pod identity |
| `status.runtimeSandboxID` | Observed CRI allocation identity |
| `status.cleanupComplete` | The controller finished disposal checks |
| `status.cleanupUnverified` | A missing allocation binding blocks disposal |

Terminal phases are `Succeeded`, `Failed`, `Cancelled`, `DeadlineExceeded`, `UnknownOutcome`, and `Rejected`.
Missing boolean status fields mean `false`.
A terminal phase alone does not prove disposal.
Wait for `status.cleanupComplete=true` before reuse or success claims.

The controller persists dispatch intent before the Pod POST.
After that point, it adopts the exact owned child or records `UnknownOutcome`.
It does not repeat a missing child's dispatch.
The finalizer holds deletion until disposal finishes.
The controller checks its own CRI sandbox and QEMU process.
It does not use a global QEMU count.

The guest receives no Kubernetes token, secret reference, or host mount.
Separate trusted components must apply source, profile, network, and identity controls.
This prototype does not install those controls.

The watchdog runs in a separate host process.
It reads cancellation and absolute deadlines from Kubernetes.
It deletes only the exact owned child with a UID precondition.
It does not allocate a child or change execution status.
It stops a guest while the lifecycle controller is down.
Both processes still need the Kubernetes API.
Native Pod `activeDeadlineSeconds` supplies a second bound during their outage.
Its clock starts at Pod start, so it does not enforce the requested absolute deadline alone.
Runtime-local deadline enforcement during API failure remains a production requirement.

## Unknown allocation recovery

A crash can lose the Pod UID and runtime binding before status records them.
If the Pod and CRI metadata then disappear, the controller cannot identify a remaining orphan VM.
It retains `cleanupUnverified=true` and the finalizer.
It never treats missing Kubernetes state as proof of VM destruction.

A trusted operator can restore an independently recorded binding:

```sh
.prototype-state/durable/bin/controller \
  --kubeconfig /tmp/konflux-sandbox-runtime/vm-kubeconfig \
  --context kind-konflux-sandbox-vm-prototype \
  --namespace foundation-durable-prototype \
  --guard "$PWD/prototypes/durable/guard.sh" \
  --recover-execution REQUEST \
  --observe-uid RECORDED_POD_UID \
  --observe-runtime-id RECORDED_CRI_SANDBOX_ID
```

The regular controller then checks the restored binding before disposal.
This administrative command trusts the operator's recorded association.
It does not authenticate a provider receipt.
Use status RBAC and a signed supervisor receipt in a production implementation.

The suite retains an unresolved intent-only object with its deletion finalizer.
Its injected crash happened before the Pod POST.
The controller has no durable provider evidence for that fact.
Later suite runs preserve this object and use a new name.

## Cleanup

After each successful suite, no prototype Pod or host controller remains.
No watchdog process remains.
The namespace retains terminal records and unresolved intent-only records.
Cluster deletion removes this disposable state.
Do not remove an unresolved finalizer to claim successful disposal.

## Runtime-local guardian experiment

```sh
make -C prototypes/durable runtime-guardian
```

This target uses `foundation-guardian-prototype`.
It runs one Kata guest at a time.
The guardian receives a trusted Pod UID, runtime sandbox ID, and expiry time.
It has no Kubernetes client or kubeconfig.
It checks the binding through CRI and stops that exact allocation at expiry.
It then observes allocations and command starts for at least 30 seconds.

Two cases use the durable Pod with `restartPolicy: Never`.
A third case uses an actual Agent Sandbox with `restartPolicy: Always`.
The shared Agent Sandbox controller and kubelet remain active.
The API server remains available.
Only this fixture's client processes stop.

Stopping the old SID does not prove disposal of the request.
The restartable session created a new SID under the same Pod UID and repeated its entrypoint command.
The fixture uses a synthetic entrypoint workload.
It does not call the sandboxd `Run` or `Start` API.
The guardian records `UnknownRuntimeOutcome` and `disposalProven=false`.
A production runtime gate must reject replacement allocation after expiry.
Identity authority must bind the allocation ID or generation as well as the Pod UID.

Results stay in `.prototype-results/durable-guardian/`.
The target restores API access for explicit cancellation or Sandbox suspension after observation.
It checks every observed SID for VM removal.
On failure, it uses UID-precondition deletion and records recovery instructions.
Unresolved Execution records retain their finalizers.
