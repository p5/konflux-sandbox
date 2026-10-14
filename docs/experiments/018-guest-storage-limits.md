# Guest storage limits

Date: 14 October 2026.

## Question

Does an emptyDir sizeLimit impose an immediate write limit inside a real Kata guest?
Does a read-only root filesystem prevent writes outside the declared volume?

## Method

Run the throwaway [storage prototype](../../prototypes/storage/README.md):

```sh
make prototype-storage
```

The suite uses the dedicated VM Kind cluster and one guest at a time.
Each guest receives an eight MiB emptyDir and attempts a sixteen MiB write.
The first volume uses memory; the second uses node disk storage.
The third case mounts an explicit eight MiB tmpfs inside the guest before it drops workload privileges.
The fourth case also installs a syscall filter after privilege drop.
The root filesystem is read-only.
The workload runs as UID 1000 without capabilities, privilege escalation, host mounts, or a Kubernetes token.
The trusted bootstrap receives only mount and identity-change capabilities, then removes all capabilities before workload execution.
The fixture attempts at most sixty-four MiB across four sequential cases.
It performs no network requests.

The observer records the actual Pod UID, CRI allocation, and matching QEMU process.
It deletes each Pod and verifies disposal before starting the next guest.
Namespace cleanup checks the original namespace UID.

## Results

The full Make target completed with exit status zero.

| Configuration | Observed write | Namespace mount attempt |
| --- | --- | --- |
| Memory emptyDir, sizeLimit eight MiB | Sixteen MiB succeeds | Succeeds |
| Disk emptyDir, sizeLimit eight MiB | Sixteen MiB succeeds | Succeeds |
| Explicit guest tmpfs, size eight MiB | ENOSPC after eight MiB | Succeeds |
| Explicit tmpfs plus syscall filter | ENOSPC after eight MiB | EPERM |

The memory emptyDir appeared as a 166584320-byte tmpfs inside this guest.
The explicit tmpfs appeared as an 8388608-byte filesystem.
Each workload had zero effective and bounding capabilities.
Each write to /tmp/outside failed with Read-only file system.
Direct remount failed in all cases.

An unprivileged user namespace could still mount a separate filesystem after capability removal.
The filtered launcher rejected unshare, namespace clone flags, setns, and mount operations.
It rejected alternate syscall ABIs and covered the newer mount API calls.
It returned ENOSYS for clone3 so ordinary process libraries could use their clone fallback.
The filtered case passed its immediate limit, remount denial, and namespace denial assertions.

The observer verified all four recorded CRI allocations and QEMU processes absent after deletion.
The suite removed its owned namespace.

## Architectural decision

Do not translate Kubernetes storage settings directly into a hard quota claim.
Expose storage guarantees as runtime and volume capabilities.
For a bounded temporary volume, install an actual guest filesystem limit through trusted bootstrap or the provider.
Remove workload mount authority and prevent namespace operations that can create another writable filesystem.
Require read-only roots and explicit budgets for every writable path in a supported profile.
A production launcher must maintain its syscall policy for the supported architecture, guest kernel, and application behavior.

## Limits

This experiment tests immediate local write behavior, not every Kubernetes eviction path.
It does not test persistent volume quotas, storage driver failure, snapshots, or forensic erasure.
A resource limit in a Pod specification does not establish a hard filesystem quota.
Production profiles must advertise only the storage guarantees that their runtime and volume implementation enforce.

The [capture](../../.prototype-results/storage/summary.json) remains an ignored local artifact.

The guest filesystem and syscall filter depend on the guest kernel.
They do not establish a host storage ceiling against guest root or a compromised guest kernel.
Those profiles need provider-enforced disk capacity or host filesystem quotas outside the guest.
