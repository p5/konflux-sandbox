# 015. External consumers of one execution foundation

## Question

Can finite checks and interactive sessions use one execution foundation without backend authority in each client?

## Scope

This composition uses two external clients and one authenticated foundation API.
The finite client requests a native Tekton TaskRun inside Kata.
The session client requests an Agent Sandbox session inside Kata.
Each client uses a scoped mTLS certificate and a separately supplied supervisor public key.
The clients run inside token-free runc Pods without host mounts or Kubernetes credentials.
The foundation owns Kubernetes operations and holds all actual guest control credentials.

## Reproduce

Prepare the dedicated VM cluster and existing runtime, identity, artifact, evidence, and firewall prerequisites.
The VM cluster must have Tekton, Kata, and Agent Sandbox installed.
Run:

```sh
make -C prototypes/consumers run
```

The Makefile builds static clients and a guest image, then loads that image into the dedicated Kind cluster.
The suite uses explicit kubeconfig `/tmp/konflux-sandbox-runtime/vm-kubeconfig` and context `kind-konflux-sandbox-vm-prototype`.
Context guards reject another cluster.
Only one 512 MiB guest runs at a time.
Go builds use two processes.

Use this command after an interrupted run:

```sh
make -C prototypes/consumers cleanup
```

Cleanup checks the namespace UID before namespace deletion.
The external firewall remains installed if the observer cannot verify guest disposal.

## Shared contract

The foundation fixes source identity, tool image digest, backend kind, and profile identity before execution.
An identical request adopts the existing record.
A changed source or profile returns HTTP 409.
Unsupported capabilities return HTTP 422.
Cross-owner access returns HTTP 403.

The clients cannot submit Pod templates, TaskSpecs, or network objects.
The foundation reports that full memory checkpoints and arbitrary TaskSpec execution are unsupported.
Both clients use shared admission, source import, transport, firewall, cleanup, and evidence functions.

The source archive and canonical manifest come from the actual artifact prototype.
The foundation transfers them through encrypted authenticated command transport.
The source helper validates the pinned manifest before archive extraction.
It validates all imported content, paths, modes, and symlink targets.
This composition uses canonical source bytes over mTLS. It does not use OCI transport.
Experiment 004 separately demonstrates actual OCI restoration inside a Kata TaskRun.
The fixture imports its fixed known source before installing the packet fence.
It releases the approved source check only after enforcement readiness.
Production must install enforcement before processing arbitrary untrusted source data.

The foundation installs an external node fence before it releases the approved check.
The fence permits the policy gateway and narrow replies to the authorized control relay.
Each backend tests allowed HTTP and HTTPS, forbidden HTTP, and a direct connection bypass.
The supervisor collects gateway audit records outside the guest.

## Evidence

The foundation removes the guest before it publishes the receipt.
The node observer checks the recorded Pod UID, CRI allocation, and matching QEMU processes before fence removal.
The shared private evidence store verifies the supervisor signature with its public key.
Clients verify the signature with a separately mounted public key.
They also verify owner, request, attempt, guest UID, backend, input identities, output digests, runtime observations, and retention.

The suite deletes the execution namespace before it retrieves archived session output, logs, and receipt.
The separate client namespace remains available for this check.
The store then rejects expired evidence with HTTP 410.
The retention period is one minute.

## Results

The composed run on 2026-10-14 passed both actual guest paths.
The finite client completed a native Kata TaskRun.
The session client completed an Agent Sandbox Kata session and repeated streamed operations through the same API.
Both clients rejected changed source and profile identities, unsupported checkpoint requests, and direct store admission.
The cross-owner client received HTTP 403.

Both guests imported manifest `sha256:89ee423a8b73b4d9ab58fb50b609cb835920a6fba73adac6d5df10ea589a50fd`.
Both guests reported kernel `6.18.35`. The node reported `7.2.9-201.fc44.x86_64`.
The native TaskRun and session ran the same source and firewall checks.
Both checks passed permitted HTTP and HTTPS, forbidden-domain rejection, and direct bypass rejection.

The observer recorded each original Pod UID, CRI sandbox ID, and QEMU PID.
Both fence records reported `removed=true` and `runtimeRemovalVerified=true` before receipt publication.
The external clients verified each signed receipt and its complete execution bindings.
The archived session client retrieved valid evidence after execution namespace deletion.
Both expired evidence reads returned HTTP 410.
The final frozen `make -C prototypes/consumers run` replay exited zero.
Both owned namespaces were absent after cleanup. No own CRI allocation remained ready.

Captures reside in ignored `prototypes/consumers/evidence/` and `prototypes/consumers/.state/` directories.
The final `evidence/result.json` contains the aggregate assertions.

Initial runs exposed a local image metadata issue before successful composition.
Containerd reported an unrelated `import-2026-10-14` alias through CRI `repoDigests` and Pod `imageID`.
The fixture now obtains the actual named image manifest through containerd and registers an explicit digest reference.
It verifies the Pod reference, OCI image annotation, resolved runtime image manifest, and manifest bytes against the frozen tool digest.
It does not use the misleading CRI alias as image identity evidence.

## Architectural result

The bounded API permits separate finite and session consumers to share execution policy and evidence handling.
The finite backend retains a native Tekton TaskRun.
The session backend uses Agent Sandbox lifecycle and authenticated command transport.
A remote execution service does not need to translate every finite Tekton step.

This fixture does not implement complete workspace or checks products.
It supports declared operations and rejects unsupported behavior.
The foundation and evidence store share one trusted process.
The supervisor signing key stays outside the guest and differs from the store's public verifier key.
Request state and store payloads remain in memory. Experiment 013 covers durable recovery separately.

The supervisor observes Pod settings, runtime allocation, process disposal, firewall rules, and gateway audit records outside the guest.
The guest supplies check output and its kernel string. This fixture provides no hardware attestation.
Store expiry deletes store payloads, but local ignored test captures remain in `.state/` and `evidence/`.
Certificate files and build output also remain in ignored directories.
The suite removes its owned namespaces and verified guest fences.
