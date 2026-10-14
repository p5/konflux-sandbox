# External consumers of one execution foundation

Two separate clients use the same authenticated foundation API:

- `finite-client` requests one native Tekton TaskRun inside Kata.
- `session-client` requests an Agent Sandbox session inside Kata and performs repeated interactive operations.

Neither client imports Kubernetes libraries or runs backend commands.
The suite launches them inside token-free runc Pods with scoped TLS files and a pinned supervisor public key.
These Pods contain no host mounts, Docker socket, or Kubernetes credentials.
The foundation owns backend resources, source import, execution identity, network enforcement, cleanup, and evidence publication.

## Prerequisites

Run the runtime, identity, artifact, private-evidence, and firewall prerequisites first.
The dedicated VM cluster must contain Kata, Tekton, and Agent Sandbox.
The local runtime and identity images must exist.
The artifact prototype must provide its canonical `source.tar` and `manifest.json` fixture.
The firewall prototype must provide its tested helper, binary, and local image.

```sh
make -C prototypes/consumers run
```

The suite uses namespace `foundation-consumers-prototype` and one 512 MiB guest at a time.
External clients use separate namespace `foundation-consumers-clients-prototype`.
Go builds use two processes to limit local load.
The namespace must be free before the suite starts.
Use `make -C prototypes/consumers cleanup` after an interrupted run.

## API contract

| Request | Purpose |
|---|---|
| `GET /capabilities` | Return supported backends, immutable input identities, and supervisor public key |
| `POST /requests/{request}` | Admit or adopt an identical immutable request |
| `GET /requests/{request}` | Observe owner-scoped execution state |
| `POST /requests/{request}/inspect` | Perform one supported session operation |
| `POST /requests/{request}/finish` | Complete the check, remove execution resources, and publish signed evidence |
| `GET /requests/{request}/evidence/{output,logs,receipt}` | Retrieve evidence after guest removal until retention expiry |

Admission fixes backend kind, canonical source digest, and profile digest.
An identical repeated request returns the existing execution.
Changed input returns HTTP 409.
Unknown capabilities return HTTP 422.
Another owner receives HTTP 403.
Expired evidence returns HTTP 410.

The submission certificate binds owner, request, and attempt.
Its `pending` guest identifier denotes a pre-allocation submission identity.
The foundation separately issues actual Pod UID identities for command transport and evidence access.
It never gives consumers its Kubernetes credentials, backend control certificates, or supervisor signing key.

## Shared execution path

Both backends use the same host-side functions to:

1. Create a fresh guest with a pinned image digest and no Kubernetes API token.
2. Issue actual execution identities and establish authenticated encrypted transport.
3. Transfer canonical source bytes and verify the pinned manifest before import.
4. Install the external firewall fence and confirm enforcement readiness.
5. Run the same source and network checks.
6. Collect results and external gateway audit records.
7. Revoke control routing, delete the guest, verify CRI and QEMU disposal, then remove its fence.
8. Store private logs and output, then sign an execution receipt outside the guest.

The finite backend starts its TaskRun with a trusted admission wait step.
It executes the approved check only after the foundation verifies source and profile readiness.
The session backend runs the check through the authenticated command interface.
Neither path accepts an arbitrary Pod template or TaskSpec from a consumer.

The firewall permits only its approved gateway and narrow replies to the authorized control relay.
It rejects new direct connections around that gateway.
The suite checks permitted HTTP and HTTPS, a forbidden domain, and a direct destination bypass for each backend.

## Evidence contract

The foundation uses the shared private-evidence module.
That module verifies the supervisor signature, full execution scope, immutable identities, and output digests.
The signing key remains separate from the store's verifier key and from guest credentials.
Consumers verify the signature against a public key that the trusted test setup supplies separately.
They also verify execution scope, backend, input identities, runtime observations, retention, and content digests.
Session evidence remains available after the suite deletes the execution namespace.
The store deletes its payloads after the one-minute retention period.

The source transfer uses actual pinned bytes over mTLS.
This composition does not claim OCI transport.
The earlier composed runtime experiment separately tested the actual OCI helper inside Kata.

## Limits

This is a bounded architectural fixture.
Foundation request state and evidence storage live in memory until the server exits.
The durable-controller prototype covers a separate recovery question.
The suite supports only its declared check and session operations.
It does not implement complete workspaces, arbitrary pipeline translation, or full memory checkpoints.

The supervisor observes Pod settings, CRI state, QEMU processes, firewall rules, and gateway audit records outside the guest.
The guest supplies check output and its kernel string. This fixture does not provide hardware attestation.
The foundation and store share one trusted process. The verifier receives only the supervisor public key.

Captures, certificate material, and scratch output stay in ignored `evidence/`, `.state/`, and `.build/` directories.
Store retention does not delete these local test captures.
The suite removes its namespaces and per-guest firewall rules after verified guest disposal.
An unverified disposal leaves its firewall in place and reports failure.

## Recovery spike

Run the separate recovery target after the same prerequisites:

```sh
make -C prototypes/consumers recovery
```

This target enables atomic filesystem records for request identity, immutable inputs, allocation binding, and command intent.
It restarts the foundation while each actual backend remains allocated.
Ready recovery adopts the exact namespace, resource UID, Pod UID, CRI sandbox ID, QEMU process, and firewall binding.
It does not create another backend or send another guest command.

The target then crashes the foundation after check acknowledgement and before result commit.
Recovery records `UnknownOutcome`, verifies guest disposal, and rejects command replay.
A separate trusted marker process observes exactly one container startup and one check for each backend.
Experiment 017 describes the captures and persistence limits.
