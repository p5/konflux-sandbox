# Aggregate prototype replay

Date: 14 October 2026.
Branch: prototype/integration-spikes.

## Commands and outcome

The final sequential replay completed with exit code 0:

```sh
make prototype-all > .prototype-results/all.log 2>&1
make prototype-validate > .prototype-results/validate.log 2>&1
```

The aggregate runs eleven scenario targets against local fixtures and the two dedicated Kind clusters.
The validation target runs Go vet, shell syntax checks, whitespace checks, and documentation link checks.
The Go compiler was go1.27.2 linux/amd64; the prototype modules declare Go 1.26.0.
No repository CI workflow was added.

## Executed paths

| Target | Observed outcome |
| --- | --- |
| prototype-recovery | Proposed attempt model handles cancellation, unknown dispatch, explicit retry, deadlines, and separate cleanup state |
| prototype-broker | Local HTTP grant, destination, method, budget, redirect, expiry, revocation, and concurrency scenarios pass |
| prototype-investigation | Synthetic reproduction, candidate validation, regressions, missing evidence, and inconclusive outcomes pass |
| prototype-artifacts | Canonical source, confined import, actual OCI helpers, actual producer rules, and proposed receipt validation pass |
| prototype-konflux | Actual signatures, Snapshots, integration outcomes, new-model skip, signing failure, managed release gates, and configuration restoration pass |
| prototype-dispatch | Client and real Tekton task use the endpoint; active cancellation and bounded process cleanup pass |
| prototype-runtime | Ordinary-container lifecycle, authenticated transport, network restriction, claims, and cleanup pass |
| prototype-vm | Kata lifecycle and network scenarios pass; native Tekton steps share one guest boot |
| prototype-composed | Actual OCI source fetch and verified import run checks inside Kata; structured source and archive identities match |
| prototype-source-entry | Actual Build Service code, local PaC parser and resolver, and resolved Tekton execution pass within their documented boundaries |
| prototype-results | Authenticated archival, diagnostics, namespace denial, and record availability after live deletion pass; log API remains disabled |

The individual reports explain which paths use actual controllers, actual upstream functions, or proposed extension rules.
Aggregate success does not turn synthetic scenarios into production security evidence.

## Final resource checks

After the aggregate completed:

- Both sandbox-runtime-prototype namespaces contained zero Pods and zero PVCs.
- The VM node contained zero QEMU processes.
- Effective ReleaseServiceConfig debug was false.
- Effective Chains insecure registry storage was false.
- The Results authorization header file was absent.
- Both local registry containers had no published host ports.

The clusters, runtime configuration, controllers, local registry, and proxy remain available for inspection.
Other fixture namespaces retain their documented resources and completed workflow objects.
The reports provide cleanup commands.

## Evidence and limits

The [aggregate log](../../.prototype-results/all.log) and [validation log](../../.prototype-results/validate.log) remain local ignored artifacts.
Rerunning the commands replaces those captures.
The source code and recorded findings remain committed prototype evidence.

The aggregate requires the retained cluster baseline and sibling upstream checkouts.
The [public setup inputs](../setup/README.md) preserve the original configuration without kubeconfig credentials.
A complete automatic fresh-cluster installer remains implementation work.

GitHub provider authorization, external publication, production identity, broad tenant isolation, and model quality remain outside these local scenarios.
