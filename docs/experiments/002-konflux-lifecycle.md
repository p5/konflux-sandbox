# Konflux lifecycle prototype

This prototype connects real Tekton, Chains, Integration Service, Release Service, and Conforma implementations.
Build metadata and check outcomes are synthetic fixtures. The fixture build does not compile repository source.

## Run

Start from the dedicated cluster described in [experiment 001](001-kind-operator.md).
Run the artifact prototype first. It supplies the local registry and immutable source artifact.

```sh
make -C prototypes/artifacts run
make -C prototypes/konflux run \
  KUBECONFIG=/tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig \
  KUBE_CONTEXT=kind-konflux-sandbox-prototype
```

The lifecycle Makefile runs four stages in sequence:

1. Reproduce the registry-port parsing failure.
2. Exercise build, Snapshot, integration results, signing, and model selection.
3. Verify debug-setting restoration after TERM interrupts the release prototype.
4. Exercise managed release admission, Conforma evaluation, and a local no-op destination.

Results go to `.prototype-results/konflux/`. Temporary files go to `.prototype-state/konflux/`.
Neither directory belongs in Git.
Mutation requires the exact dedicated context, loopback API endpoint, matching Docker API port, and expected Kind node identity.

## Installed components

The existing cluster provides Tekton, Chains, Application API, Integration Service, and certificate management.
This prototype adds two operator child resources:

- `KonfluxEnterpriseContract`, with default policy deployment disabled.
- `KonfluxReleaseService`, with one controller replica.

The operator installs Release Service from revision `3195ea2052623fc0c319e1e1a2f99a743e8b0e0b`.
Integration Service runs revision `a5e72c8f7f38fef128feccdda1de53d99a6823f4`.
Conforma CLI source is pinned to `v0.9.64`. The local binary reports its build version as `development`.
The release image includes the inspected upstream policy files.
`release-policy-commit.txt` records their exact revision.

No Build Service, GitHub App, webhook integration, or external destination is required.
Git reporting fails with missing provider metadata. Snapshot and integration processing still complete.

## Build and Snapshot boundary

Each legacy fixture has an Application, Component, IntegrationTestScenario, and build-labelled PipelineRun.
The build task returns these required results:

```text
IMAGE_URL
IMAGE_DIGEST
CHAINS-GIT_URL
CHAINS-GIT_COMMIT
```

Pipeline results must reference task results. Tekton rejects literal Pipeline result values in the inspected version.

Chains creates a real image signature and SLSA attestation in the local registry.
The prototype waits for `chains.tekton.dev/signed=true` and the controller-created Snapshot annotation.
Cosign verifies both signatures with the published Chains public key.
The prototype does not read the signing key.

Relevant code:

- [Build routing predicate](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/predicates.go#L57).
- [Legacy Snapshot creation](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/internal/controller/buildpipeline/buildpipeline_adapter.go#L437).
- [Build result extraction](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/utils.go#L121).

Evidence: `pass-build.json`, `pass-snapshot.json`, `cosign-image-verification.json`, and `cosign-attestation-verification.json`.

## Integration result boundary

The real Integration Service resolves a namespace-local Pipeline through Tekton's cluster resolver.
Each scenario belongs to a separate Application. The Pipeline emits a task result named `TEST_OUTPUT`.

Required fields are `result`, `timestamp`, `successes`, `failures`, and `warnings`.
Supported result values are `SUCCESS`, `FAILURE`, `WARNING`, `SKIPPED`, and `ERROR`.

| Fixture | Tekton outcome | Snapshot test status |
|---|---|---|
| Valid `SUCCESS` | Succeeded | `TestPassed` |
| Valid `FAILURE` | Succeeded | `TestFail` |
| `SUCCESS` with missing required fields | Succeeded | `TestFail`, with schema error |
| Cancelled PipelineRun | Cancelled | `TestFail` |

The semantic-failure fixture exits zero. This proves that Tekton success and test success have different meanings.
The malformed fixture reports the missing fields in its Snapshot status detail.
Cancellation retains the detailed Tekton reason. Snapshot test status combines cancellation with ordinary test failure.
The cancellation scenario waits for a running task step before it sends the cancellation request.
`cancel-task-before-cancel.json` records that precondition.

Relevant code:

- [Required output schema](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/helpers/integration.go#L86).
- [Integration result evaluation](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/internal/controller/integrationpipeline/integrationpipeline_adapter.go#L157).
- [Snapshot input parameter](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/integration_pipeline.go#L483).

Evidence: `{pass,fail,malformed,cancel}-{summary,integration,snapshot,taskruns}.json`.

## New-model gate

The prototype also submits a successful signed PipelineRun with these labels:

```yaml
pipelines.konflux-ci.dev/type: build
build.konflux-ci.dev/component: fixture-new-model
```

Integration Service logs `Skipping new-model build PipelineRun; Snapshot creation is not enabled yet`.
It creates no Snapshot for this run. Its build finalizers are absent; Chains and Results finalizers can remain.

The [build controller](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/internal/controller/buildpipeline/buildpipeline_controller.go#L92) returns before loading ComponentGroup data.
The [model selector](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/utils.go#L119) checks the new label keys.
This path has no feature switch.

The same controller contains the intended ComponentGroup Snapshot adapter.
This experiment does not establish another controller that owns the gated path.
It does not prove that every transitional ComponentGroup path is disabled.

Evidence: `new-model-input.json`, `new-model-build.json`, `new-model-controller.log`, and `new-model-summary.json`.

## Chains completion and trust

Integration Service accepts the presence of `chains.tekton.dev/signed` as Chains completion.
It also accepts the value `failed`. Its source explicitly delegates trust decisions to downstream verification.

Server admission removes a supplied `failed` annotation in a separate dry-run probe.
The prototype therefore does not use an injected completion marker as signing-failure evidence.
`admission-marker-{input,response,summary}.json` records that probe.

The signing-failure scenario creates a separate unsigned OCI subject in a dedicated fixture repository.
The local proxy denies writes to that repository. It still permits reads.
Task result names prevent that fixture from producing an image signature through TaskRun signing.
Chains uses its unchanged retry policy and writes its own terminal completion annotation.
The prototype waits at most 180 seconds for the expected failure and controller-created Snapshot.

The retry limit is three. The [retry handler](https://github.com/tektoncd/chains/blob/v0.29.7/pkg/chains/annotations/annotations.go#L158) increments the retry marker, then calls `MarkFailed`.
This experiment does not change the retry limit or impersonate the signer.
It demonstrates that Snapshot creation and cryptographic admission have separate responsibilities.

Relevant code:

- [Chains completion check](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/utils.go#L89).
- [Chains reconciled values](https://github.com/tektoncd/chains/blob/v0.29.7/pkg/chains/annotations/annotations.go#L60).

Evidence: `failed-marker-{input,build,summary,verification}.json` and `failed-marker-verification.log`.

## Registry-port failure

The isolated `registry-port-bug` target uses the original local registry endpoint, including port `5000`.
It asserts this observed transformation:

```text
IMAGE_URL: 172.18.0.5:5000/prototype/source
IMAGE_DIGEST: sha256:<digest>
Snapshot: 172.18.0.5@sha256:<digest>
```

The [pullspec function](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/build_pipeline.go#L195) splits `IMAGE_URL` at the first colon.
That operation removes the registry port and repository path.
The prototype checks the real controller-created Snapshot. It does not repair the Snapshot.
Conforma then rejects that Snapshot's image reference.

This is a reference-parsing failure in the inspected function and legacy workflow.
Use an OCI reference parser when contributing a fix. Preserve the registry authority and repository before replacing the tag with a digest.

The remaining scenarios use a port-80 proxy as a separate workaround.
Its portless registry identity survives the current parsing function.
The original registry, artifact content, and upstream code remain unchanged.

Evidence: `port-bug-{build,snapshot,summary}.json`, `port-bug-conforma.{json,log}`, and `registry-proxy.json`.
`registry-port-bug/` also preserves the first managed release rejection caused by this failure.

## Managed release boundary

The release fixture uses the successful controller-created Snapshot through a ReleasePlan and ReleasePlanAdmission.
Release Service constructs the managed PipelineRun and passes these parameters:

```text
release
releasePlan
releasePlanAdmission
releaseServiceConfig
snapshot
enterpriseContractPolicy
```

The `snapshot` parameter is a Kubernetes reference. The `enterpriseContractPolicy` parameter contains the policy specification as JSON.

The trusted fixture task reads the Snapshot through a dedicated service account.
It then runs real Conforma signature validation and upstream policy evaluation.
The final step writes a local no-op result. It does not publish an artifact.

The selected policy packages are `attestation_type` and `slsa_provenance_available`.
The permit policy accepts SLSA provenance `v0.2`.
The reject policy requires a different predicate type, while keeping the same real public key.
Therefore, policy rejection is distinct from signature failure.

The fixture first requests a cluster-resolved release with debug mode disabled.
It checks the effective ReleaseServiceConfig setting before submitting that request.
Release Service rejects that source before creating a managed PipelineRun.
The prototype then enables debug mode for the local resolver.
An exit handler restores the previous debug setting on success, failure, or handled interruption.
The handler waits for the effective ReleaseServiceConfig setting to match.
Production integration needs an approved immutable pipeline source.

| Fixture | Observed release state | Destination |
|---|---|---|
| Cluster resolver with debug disabled | Validation failed | No managed PipelineRun |
| Accepted provenance predicate | Released | Local no-op step executed |
| Rejected provenance predicate | Failed managed attempt | Local no-op step skipped |

Rejection assertions require the upstream rule code `slsa_provenance_available.attestation_predicate_type_accepted`.
An infrastructure failure cannot satisfy that assertion.
Conforma reports image and attestation signature success before the predicate-type rejection.

Each replay creates a new ReleasePlan and ReleasePlanAdmission with an explicit admission selector.
The prototype observes admission reconciliation before it creates the plan.
This avoids stale matching state from changing Application associations on reused fixture resources.

This selected policy is smaller than Konflux's production release policy.
Passing it does not establish production-policy conformance.

Relevant code:

- [Managed release construction](https://github.com/konflux-ci/release-service/blob/3195ea2052623fc0c319e1e1a2f99a743e8b0e0b/controllers/release/adapter.go#L1395).
- [Object reference parameters](https://github.com/konflux-ci/release-service/blob/3195ea2052623fc0c319e1e1a2f99a743e8b0e0b/tekton/utils/pipeline_run_builder.go#L124).
- [Policy specification parameter](https://github.com/konflux-ci/release-service/blob/3195ea2052623fc0c319e1e1a2f99a743e8b0e0b/tekton/utils/pipeline_run_builder.go#L145).
- [Release source validation](https://github.com/konflux-ci/release-service/blob/3195ea2052623fc0c319e1e1a2f99a743e8b0e0b/controllers/release/adapter.go#L2284).

Evidence: `release-{debug-blocked,permit,reject}.json`, matching `*-pipelines.json`, and matching `*-task-logs.txt`.

## Architecture decisions

1. Keep exploratory execution outside build and integration type labels.
2. Export approved candidates into a supported build and Snapshot path.
3. Preserve raw execution reasons alongside standardized `TEST_OUTPUT` results.
4. Require cryptographic verification before trusting execution evidence.
5. Treat Snapshot creation and release admission as separate decisions.
6. Pass immutable evidence to trusted release tasks. Do not grant guest workloads release authority.
7. Track the new-model gate and registry-port parser as explicit integration dependencies.

## Scope and cleanup

These workflows use normal container Pods. They do not prove VM isolation or sandbox network enforcement.
No GitHub webhook, source checkout, production build, model provider, or external publication is exercised.

The prototype temporarily enables plain HTTP OCI storage in the disposable cluster's Chains configuration.
An exit handler restores the previous option and checks the effective Chains ConfigMap.
INT and TERM handlers exit through configuration restoration.
`chains-restored.json` and `release-debug-restored.json` record successful restoration.
`release-interrupt-restoration.json` records an observed TERM exit with status 143 and restored debug mode.
This signal probe checks configuration restoration. It does not prove cancellation of an already-created release workflow.
The published public key is the only key material exported.

The proxy container is `konflux-sandbox-lifecycle-registry-proxy`.
Its configuration is `.prototype-state/konflux/nginx.conf`. No host port is published.
The original artifact registry remains separately owned by the artifact prototype.

Delete only this prototype's namespace when finished:

```sh
make -C prototypes/konflux cleanup
docker rm -f konflux-sandbox-lifecycle-registry-proxy
```

Operator-managed release and policy components remain installed for follow-up work.
The dedicated Kind cluster and its kubeconfig remain outside the repository.
