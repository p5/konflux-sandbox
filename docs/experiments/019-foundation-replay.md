# Foundation prototype replay

Date: 14 October 2026.
Branch: prototype/integration-spikes.

## Command

```sh
GOFLAGS=-p=2 GOMAXPROCS=2 make prototype-all > .prototype-results/all.log 2>&1
```

The target runs twenty scenario targets sequentially, then static validation.
It includes the original eleven scenarios and nine foundation scenarios.
All live workloads use the two dedicated Kind clusters and local fixtures.
The compiler is Go 1.27.2; prototype modules declare Go 1.26.
No repository CI workflow is required.

## Replay status

The twenty-target aggregate completed with exit code zero.
Go vet, shell syntax, whitespace, and documentation link checks also passed.

The final resource check found four stale firewall administration port-forwards from fixture wrapper processes.
The launcher now tracks kubectl directly.
The corrected full firewall Make target, including failure cases, passed again.
The audit confirmed no remaining fixture process after that replay.

The first attempt stopped at the historical Build Service transport-error assertion.
The sibling checkout now contains the user's background fix on branch fix/pac-trigger-transport-error.
Commit 684936c825d359d8106fa950bb3fab594ea7a00c returns the error and preserves ECONNREFUSED through errors.Is.
The updated harness expects the corrected behavior by default and passed independently.
The historical nil-return reproduction remains available through BUILD_SERVICE_TRANSPORT_EXPECTATION=nil with the original revision.
The [revision inventory](../prototype-revisions.tsv) records both source baselines.
No prototype change modifies that sibling checkout or asserts upstream merge status.

## Additional scenarios

| Target | Question answered |
| --- | --- |
| prototype-firewall | Domain/IP enforcement, controlled DNS, shared addresses, revocation, gateway loss, and verified fence cleanup |
| prototype-identity | Scoped mTLS, external authorization, encrypted commands/files, stale guest rejection, and broker revocation |
| prototype-durable | Durable attempts, exact adoption, unknown outcomes, finalizers, and controller-independent cancellation |
| prototype-guardian | API-independent allocation stop and actual restartable session replacement behavior |
| prototype-private-evidence | Owner access, streamed logs, signed observations, immutable artifacts, and fixed retention |
| prototype-consumers | Finite and session clients share one interface without backend credentials |
| prototype-broker-network | Operation grants and destination profiles jointly control credential-bearing egress |
| prototype-consumer-recovery | Actual TaskRun and Sandbox recovery avoids startup and command replay |
| prototype-storage | Actual volume limits require filesystem enforcement and namespace restrictions |

The [initial aggregate report](010-aggregate-replay.md) describes the original eleven scenarios.
The individual reports distinguish real controller behavior from proposed extension contracts.

## Architecture conclusions

Use a small shared Execution API above native Tekton tasks and Agent Sandbox session allocation.
Keep product controllers outside this repository.
Add trusted node supervision, an outside firewall, scoped credential operations, and private evidence interfaces.
Existing Konflux resource schemas need no required field changes.

Bind execution authority to the actual provider allocation ID or generation, not only Pod UID.
The guardian observed a new VM and repeated synthetic entrypoint under one unchanged Pod UID after it stopped the old allocation.
This does not demonstrate sandboxd API-command replay.
Runtime admission must prevent an expired allocation from authorizing another workload start.

Treat missing acknowledgement or result commit as an unknown outcome.
Both actual backend recovery cases adopted exact bindings and disposed of uncertain execution without replay.
Keep outside enforcement until the observer verifies allocation disposal.

Advertise explicit firewall protocol capabilities.
The initial profile uses inspected HTTP/S domains and explicit IPv4 TCP IP or CIDR grants.
Unsupported UDP, IPv6 access, and opaque domain tunnels fail admission.
The trusted gateway can read inspected traffic and belongs inside the relevant credential trust boundary.

Do not infer hard filesystem quotas from emptyDir sizeLimit.
The bounded storage experiment requires an explicit guest filesystem limit and a filter that prevents the tested namespace mount bypass.
Every writable path needs its own supported enforcement and conformance checks.

## Resource checks and limits

Final checks recorded zero owned Pods, PVCs, ready CRI allocations, QEMU processes, packet chains, and host fixture processes.
The ordinary runtime namespace also contained zero Pods and PVCs.
Effective Release Service debug and Chains insecure registry storage were false.
Neither local registry container published host ports.
All 36 research checkouts remained source-clean.

Four deliberate intent-only requests retain cleanupUnverified and deletion finalizers.
No live allocation belongs to those requests.
One completed guardian record needed a final controller reconciliation after the harness stopped.
The controller removed that completed finalizer; it left the four uncertain records unchanged.

The [runtime audit](../../.prototype-results/foundation-resource-check.json) and [platform audit](../../.prototype-results/foundation-platform-check.json) preserve the final state.

The clusters, controllers, runtime configuration, registry, and portless registry proxy remain available for inspection.
Durable experiments retain terminal records and unresolved intent-only deletion finalizers.
Raw captures and fixture credentials stay in ignored directories.
Evidence API retention does not delete local test captures or client copies.

Production work includes supported node/runtime adapters, durable private storage, issuer lifecycle, concurrent ownership, and deployment RBAC.
The fixtures do not establish complete tenant isolation, hardware attestation, or production availability guarantees.
GitHub App delivery and provider publication remain outside the user's selected local boundary.

The [aggregate log](../../.prototype-results/all.log), [initial failed attempt](../../.prototype-results/all-initial-foundation.log), and [firewall cleanup replay](../../.prototype-results/firewall-final-cleanup-replay.log) remain ignored captures.
The final [validation log](../../.prototype-results/validate.log) records checks after documentation and cleanup corrections.
