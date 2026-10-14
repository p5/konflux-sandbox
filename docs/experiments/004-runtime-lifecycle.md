# Runtime lifecycle and VM execution

Date: 2026-10-14.

## Result

Agent Sandbox and Kata can run the proposed execution environment on this machine.
The prototype ran real guest commands, file transfers, PTYs, cancellation, suspension, and warm-pool claims.
An ordinary Tekton TaskRun also completed inside a Kata VM.

This proves runtime compatibility for the tested operations.
It does not prove complete tenant isolation or production readiness.

## Environment

| Component | Observed version |
|---|---|
| Kind node image | `kindest/node:v1.37.0` |
| Kubernetes | `v1.37.0` |
| containerd | `2.3.4` |
| Node and ordinary container kernel | `7.2.9-201.fc44.x86_64` |
| Agent Sandbox controller | `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.6` |
| sandboxd source | `5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1` |
| sandboxd build toolchain | `go1.27.2 linux/amd64` |
| Kata Containers | `4.2.0`, Rust shim commit `c7351e797efff8bfc6bd73da0eb1909be12e2cfe` |
| QEMU | `11.0.1`, Kata static package |
| Guest kernel | `6.18.35` |
| Tekton Pipelines | `v1.15.3` |
| ORAS | `v1.3.4`, official static release binary |
| Trusted Artifact helper source | `dbbc7016f5867e204ced75a64a8ce3668723067d` |
| KindNet | `kindest/kindnetd:v20260820-69b56db7` |

The execution image uses a pinned Debian base manifest.
The observed final image ID was `sha256:5a882cf1489eeae083d7977d464dfdbdd9afc9bd7d9d7885d062ff2e2d73e6f6`.
Rebuilding can change that ID because Debian package repositories change.

The Kata archive checksum matched its GitHub release asset digest:

```text
b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8
```

## Scope and installation

The ordinary-container experiment used the existing disposable Konflux cluster.
The VM experiment used a separate disposable cluster, `konflux-sandbox-vm-prototype`.
Its private kubeconfig is `/tmp/konflux-sandbox-runtime/vm-kubeconfig`.
Both experiments used namespace `sandbox-runtime-prototype`.

Every runtime command checks its explicit kubeconfig before cluster operations.
The guard accepts only the two dedicated Kind context names and verifies their API endpoint against Kind's local inventory.
The command then selects that context explicitly and checks its expected node.
Negative tests reject another context and a known context name with another API endpoint.
The VM installer regenerates its private kubeconfig when the cluster already exists.
That recovery path passed after the private kubeconfig was temporarily moved.

The installer extracted official Kata binaries into the VM node's `/opt/kata`.
It registered `kata-prototype` in that node's containerd configuration and created a matching RuntimeClass.
The default Kata QEMU configuration remained selected.
The installer loaded no kernel modules and changed no host services or global container settings.

Two node prerequisites needed changes inside the disposable node:

1. Install and start DBus for Kata's systemd cgroup integration.
2. Increase that container's `/dev/shm` limit from 64 MiB to 2 GiB.

The first attempt failed with a missing DBus socket.
The next attempt reached QEMU but failed with `error: kvm run failed Bad address`.
Increasing `/dev/shm` allowed the guest to boot.
An intermediate `virtio-blk-pci` root filesystem configuration also booted after that change.
The final successful tests used the default `virtio-pmem` configuration.

KVM device presence alone therefore did not establish backend readiness.

## Executed checks

| Operation | Ordinary container | Kata VM |
|---|---|---|
| Sandbox creation and Ready condition | Passed | Passed |
| Unauthenticated file write | HTTP 401 | HTTP 401 |
| Unauthenticated gRPC command | `Unauthenticated` | `Unauthenticated` |
| Authenticated upload, execute, and download | Passed | Passed |
| Guest command reads uploaded source | Passed | Passed |
| No mounted service account token | Passed | Passed |
| PTY start and resize | Passed | Passed |
| Process-group SIGTERM | Exit 143 | Exit 143 |
| Suspension removes backing Pod | Passed | Passed |
| Suspension retains workspace PVC | Passed | Passed |
| Resume creates another Pod UID | Passed | Passed |
| Resume retains source file | Passed | Passed |
| Old process handle after resume | `NotFound` | `NotFound` |
| Sandbox deletion removes Pod and PVC | Passed | Passed |
| Claim adopts an existing warm Pod without changing its UID | Passed | Passed |
| Warm pool replenishes adopted capacity | Passed | Passed |
| Claim deletion removes its Sandbox and Pod | Passed | Passed |

The node and ordinary container reported the same kernel version.
The Kata guest reported a different kernel version.
That observation, the selected RuntimeClass, and QEMU's KVM process establish actual VM execution in this experiment.

Sandbox suspension did not preserve the process or its PTY.
The PVC preserved files, while the new daemon rejected the previous process handle.
Workspace suspension must therefore describe file persistence explicitly.
Full process restoration requires another tested capability.

The claim test waits for exactly one claimed Sandbox and one ready replacement owned by the pool.
It checks owner UIDs and verifies that the replacement Pod UID differs from the adopted Pod UID.
This avoids accepting a stale pool status during replenishment.

## Transport integration

Direct `kubectl port-forward pod/lifecycle` worked for the ordinary container.
It failed for Kata because containerd connected to loopback in the host-side Pod network namespace.
The service listened inside the guest.
The observed error included `failed to connect to localhost:8080` and `connection refused`.

The VM prototype created a separate ordinary-container TCP proxy Pod.
It forwarded ports 8080 and 9090 to the guest Pod IP.
An API-server-authorized port-forward reached that proxy.
The guest daemon also checked a random token for this Sandbox.
Only the token's SHA-256 digest appeared in its command arguments.

This preserved gRPC streaming and REST file transfer.
It requires proxy recreation when suspension changes the guest Pod IP.
The prototype did that before reconnecting.

The inspected upstream sandbox-router documentation states that its upstream HTTP/1 transport cannot carry sandboxd gRPC.
Do not assume that router supplies the complete command transport.
Production needs an HTTP/2-capable route or another transport that preserves gRPC streams and trailers.

The prototype used plaintext traffic inside the disposable cluster and synthetic inputs.
Production needs authenticated encryption and restrictions on direct guest access.
The daemon's bearer token is an ingress control credential, not an upstream Git or model credential.
This experiment did not implement credential expiry or rotation.

## Network enforcement

The network probe tested an ordinary client and a Kata client separately.
Each connected to a synthetic HTTP target through its direct Pod IP.

Both runs produced this sequence:

```text
Baseline: HTTP/1.0 200 OK
Deny-all egress NetworkPolicy: connection times out, exit 124
Delete policy: HTTP/1.0 200 OK
```

The installed KindNet enforced the tested policy for both runtimes.
Do not infer that all Kind installations lack NetworkPolicy support.

This tested one direct Pod connection.
DNS restrictions, external destinations, metadata endpoints, IPv6, other nodes, and bypass attempts remain untested.
Backend readiness must include enforcement checks for the actual execution profile.
A NetworkPolicy object alone is insufficient evidence.

## Direct Tekton integration

The dedicated VM cluster installed the official Tekton Pipelines `v1.15.3` release manifest.
A TaskRun selected `podTemplate.runtimeClassName: kata-prototype`.
Two ordinary script steps completed successfully.

The first step exported guest kernel version `6.18.35` as a TaskRun result.
Both steps observed the same kernel boot ID.
Neither needed a mounted service account token.
The TaskRun reported `Succeeded=True`, with reason `Succeeded`.

This proves that Tekton can execute existing step mechanics directly inside this VM runtime.
The VM covers the TaskRun Pod; individual steps share its guest kernel.
This path does not require remote task dispatch for every check.

It does not add the shared service's source identity, broker, authorization, evidence, or workspace lifecycle contract.
Those functions still need extension code and policy.
The remote service adapter and direct RuntimeClass path should implement the same execution profile semantics.

## Composed source, OCI, and VM check

The composed prototype reused the artifact prototype's actual selected working-tree export.
It fetched the immutable OCI blob from the shared disposable registry at `172.18.0.5:5000`.
The host verified the blob digest before reading its source archive and manifest.
The source helper verified the pinned manifest identity, bounded archive, and restored content before guest execution.

The TaskRun then fetched that same artifact from inside its Kata guest.
It used the unchanged upstream `use-oci.sh`, `oras_opts.sh`, and `select-oci-auth.sh` scripts.
ORAS supplied actual registry transport. No ConfigMap carried the source.
A single-attempt adapter supplied the unavailable `retry` command.
The registry used plaintext HTTP with synthetic content and no credentials.

The first step checked the source archive digest and safely imported its contents into a fresh workspace directory.
The second step ran the exported executable and checked the actual selected source.
It verified staged content, unstaged content, explicitly selected content, executable behavior, and the symlink target.
It also verified that the deleted path and excluded file were absent.

The successful TaskRun returned these results:

```json
{
  "source_digest": "sha256:89ee423a8b73b4d9ab58fb50b609cb835920a6fba73adac6d5df10ea589a50fd",
  "archive_digest": "sha256:7bfa41f22d7d95940022772f3c5e8264957e9458d1932c166f5d891d87cfa2d8",
  "guest_kernel": "6.18.35",
  "check_status": "passed"
}
```

The observed outer Trusted Artifact blob digest was:

```text
sha256:911036b5b20d250b1d3e62ff78d56fadf478b5e34ae9b6688e56b7b15fe45826
```

The first attempt exposed an integration constraint.
Kubernetes created the second step's working directory before the first step imported source.
The importer correctly rejected that existing destination.
The successful attempt used the workspace root as the container working directory and executed `cd tree` after import.
Future task adapters must preserve this distinction.

This proves that direct VM TaskRuns can reuse existing artifact transport and ordinary workspace/result mechanics.
We do not need to translate every existing task through a remote command service.
The shared execution contract can support direct VM tasks and interactive remote sessions through different adapters.

The check was synthetic, and the envelope contained known fixture files.
The inner source importer validates archive paths and manifest content.
The unchanged upstream helper extracts the outer envelope with GNU tar.
Production still needs bounded validation of that outer envelope and authenticated registry transport.
The TaskRun results are workload output, not trusted proof of enforcement or signed release approval.
This experiment did not test Chains or Conforma on the VM cluster.

## Architecture consequences

- Keep Agent Sandbox lifecycle separate from low-level VM isolation.
- Use its warm-pool claim lifecycle instead of writing another allocator.
- Add guest command transport as an explicit backend capability.
- Preserve REST and streaming gRPC through any gateway.
- Treat file suspension and full process restoration as different capabilities.
- Permit direct Tekton VM execution where it satisfies the execution contract.
- Verify network enforcement before accepting a restricted profile.
- Keep trusted receipts outside the guest. Guest output cannot prove enforcement.
- Mint credentials for each claimed execution. Shared templates must not share execution credentials.

## Reproduction and cleanup

Run commands from `prototypes/runtime`.
The scripts use synthetic data and disposable namespaces.

```sh
make run
make vm-run
make tekton-install tekton-test
make -C ../artifacts source transport
make composed
```

`make run` uses the existing Konflux prototype kubeconfig by default.
Override `KUBECONFIG` and `CLUSTER` when that cluster changes.
The default upstream source path is `../../../agent-sandbox`.

`make vm-run` creates and configures the separate VM cluster.
The Kata archive is approximately 997 MB.
The first run requires network access, Docker, Kind, kubectl, Go, zstd, curl, grpcurl, and OpenSSL.
The tested host already exposed `/dev/kvm` and `/dev/vhost-vsock` to its privileged Kind node.
Other hosts can require platform preparation outside this prototype's scope.

Local captures are in `prototypes/runtime/evidence/` and are ignored by Git.
They include command results, Sandbox status, claim status, and TaskRun evidence.
Reruns replace the top-level captures.
Run prototype targets sequentially to preserve those captures.

The tests removed their Sandbox, claim, pool, proxy, network probe, and TaskRun resources.
Both namespaces remain available.
Agent Sandbox controllers remain installed in both clusters.
The VM cluster also retains its Kata RuntimeClass, node configuration, and Tekton controllers.
No QEMU guest remained after cleanup.

```sh
make cleanup
make cleanup KUBECONFIG=/tmp/konflux-sandbox-runtime/vm-kubeconfig
make vm-cleanup
```

Deleting the VM cluster removes its node-local Kata and DBus installation.
The downloaded archive remains in `/tmp/konflux-sandbox-runtime` until temporary storage is cleared.

## Sources

- [Agent Sandbox installation](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.6)
- [Sandbox daemon contract and transport limitations](https://github.com/kubernetes-sigs/agent-sandbox/blob/5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1/packages/sandboxd/USER_GUIDE.md)
- [Agent Sandbox suspension implementation](https://github.com/kubernetes-sigs/agent-sandbox/blob/5d7608a9fca5aa1d3a12b73fb51ed2ee0d4e9ab1/controllers/sandbox_controller.go)
- [Kata static release](https://github.com/kata-containers/kata-containers/releases/tag/4.2.0)
- [Kata containerd configuration](https://github.com/kata-containers/kata-containers/blob/4.2.0/docs/how-to/containerd-kata.md)
- [Tekton release](https://github.com/tektoncd/pipeline/releases/tag/v1.15.3)
- [ORAS release](https://github.com/oras-project/oras/releases/tag/v1.3.4)
- [Trusted Artifact restore helper](https://github.com/konflux-ci/build-trusted-artifacts/blob/dbbc7016f5867e204ced75a64a8ce3668723067d/use-oci.sh)
- [Source validation prototype](../../prototypes/artifacts/main.go)
