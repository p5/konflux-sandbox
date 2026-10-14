# 017. Recovery across both execution backends

## Question

Can one foundation recover native Tekton TaskRuns and Agent Sandbox sessions without allocation or command replay?

## Scope

This experiment extends the shared foundation from experiment 015 with optional filesystem persistence.
The normal `run` target retains its existing behavior.
The separate `recovery` target runs actual Kata guests through both existing backend adapters.
Only one guest runs at a time.
The experiment does not claim production storage or automatic command retry.

## Reproduce

Prepare the same prerequisites as experiment 015.
Run:

```sh
make -C prototypes/consumers recovery
```

The target uses the dedicated VM kubeconfig and context guards from experiment 015.
It uses the same owned namespaces and verified cleanup procedure.
Go builds use two processes.

## Persistence boundary

The foundation persists owner, request, attempt, source digest, profile digest, tool digest, and namespace UID before allocation.
It writes the observed resource UID, Pod UID, and CRI sandbox ID before authenticated bootstrap and source-check commands.
Container startup necessarily precedes the observer's allocation capture.
Its initial trusted marker contains no source execution.

Each filesystem update uses a temporary file, file synchronization, atomic rename, and directory synchronization.
The allocation binding also records the installed firewall rule digest and policy gateway UID before check admission.
The foundation persists `Ready` only after transport, source import, and enforcement setup complete.
The supervisor key persists separately in ignored fixture storage.
The fixture does not implement concurrent writers or a storage transaction across multiple files.

## Ready recovery

The fixture stops and restarts the foundation while each actual backend remains allocated.
Recovery requires the same immutable inputs, namespace UID, resource UID, Pod UID, and CRI sandbox ID.
It verifies the Pod owner reference, runtime class, absence of a Kubernetes token, and current CRI readiness.
It requires the original QEMU process with the exact recorded CRI sandbox ID.
It also verifies the exact firewall rule digest, required node hooks, original policy gateway UID, gateway readiness, and profile bytes.
Recovery sends no guest command and creates no backend object.
An identical owner request adopts the existing record.

Changed or missing bindings produce `UnknownOutcome` with blocked cleanup.
The foundation retains capacity until it validates disposal.
A changed CRI sandbox ID within the same Pod UID cannot pass adoption.
The bounded negative check changes the expected sandbox ID and verifies rejection against the unchanged actual Pod.
It does not replace the actual runtime allocation during that check.

## Command uncertainty

The foundation persists `CommandIntent` before it dispatches the check.
Both backends execute the same approved source and firewall check from experiment 015.
The fixture injects a process exit after the backend acknowledges execution and before the foundation commits a result.
The external identity gateway, policy gateway, node fence, and guest continue independently of that process.

Recovery treats the persisted intent as `UnknownOutcome`.
It validates the allocation binding and removes the guest through the existing verified disposal path.
It removes the firewall only after Pod, CRI, and QEMU observations confirm disposal.
The foundation rejects another finish request and does not publish a successful receipt.
It does not rerun the check.

## External counters

A separate trusted runc Pod counts startup and command markers.
The actual guest container emits its startup marker once.
The approved check emits its command marker before source execution.
Both markers pass through the actual policy gateway.
The marker process survives all foundation restarts.
The host observer reads its counters through an authenticated Kubernetes port-forward.
Each backend must finish with one startup marker and one command marker.

These counters verify execution of this known synthetic fixture.
They do not attest arbitrary guest code or provide cryptographic proof that a malicious guest followed the marker contract.

## Results

The frozen `make -C prototypes/consumers recovery` run passed on 2026-10-14 with exit status zero.
Both backends retained their exact namespace, resource UID, Pod UID, CRI sandbox ID, QEMU PID, and enforcement binding across restart.
Both identical request submissions adopted the original execution without resource creation.
The changed expected sandbox ID failed adoption while the actual Pod UID remained unchanged.

Both actual checks completed before the injected foundation exit.
The durable records remained `CommandIntent` because the foundation did not commit their acknowledged results.
Each subsequent restart produced `UnknownOutcome` and cleanup state `Verified`.
Further finish and receipt requests returned HTTP 409.
No success receipt existed for either uncertain execution.

The external marker process reported:

```json
{"command/finite":1,"command/session":1,"startup/finite":1,"startup/session":1}
```

Both recorded fences reported verified runtime removal.
Both owned namespaces were absent after cleanup. No own CRI allocation remained ready.

Ignored captures include `prototypes/consumers/evidence/recovery-run.log`, `recovery-result.json`, and `recovery-counts.json`.
The same directory contains each final durable record and its fence observation.
Per-run filesystem journals, transport files, source captures, and backend logs remain in ignored `.state/` storage.

## Limits

The persistence covers execution recovery and command uncertainty.
It does not persist private evidence store payloads or recover a completed archive after store process loss.
The separate evidence experiment covers its own retention and signature boundaries.
The fixture does not retry uncertain commands, translate arbitrary TaskSpecs, or restore guest memory.
Its files remain in ignored `.state/` storage and are not a production database.
