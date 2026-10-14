# Guest storage limits prototype

This throwaway experiment checks whether Kubernetes storage settings produce an immediate write limit inside Kata.
It compares memory-backed and disk-backed emptyDir settings with an explicit guest tmpfs limit.
A fourth case adds a syscall filter after trusted bootstrap and privilege drop.
Each guest attempts a sixteen MiB write and a write outside its approved volume.
The root filesystem is read-only, and the workload has no capabilities or Kubernetes token.
The trusted tmpfs bootstrap briefly receives mount and identity-change capabilities inside the guest.
It drops those capabilities and changes to UID 1000 before it starts the workload.

Run after the runtime prototype installs the dedicated VM cluster:

```sh
make -C prototypes/storage run
```

The command runs one guest at a time in foundation-storage-prototype.
It removes its owned namespace and verifies recorded runtime allocations after execution.
Captures stay under ignored .prototype-results/storage/.
The experiment performs no network requests and does not test persistent volume quotas.
It observes eight MiB emptyDir settings accepting sixteen MiB inside this Kata setup.
An explicit eight MiB tmpfs returns ENOSPC, but unprivileged namespace creation can mount another filesystem.
The filtered case rejects mount and namespace operations and preserves the tested volume limit.
The syscall filter targets Linux AMD64 only and is not a complete production security policy.
It returns ENOSYS for clone3 so ordinary process libraries can use their clone fallback.
Other writable paths and total storage budgets require separate profile conformance.

The guest filesystem and syscall filter depend on the guest kernel.
They do not establish a host storage ceiling against guest root or a compromised guest kernel.
Those profiles need provider-enforced disk capacity or host filesystem quotas outside the guest.
