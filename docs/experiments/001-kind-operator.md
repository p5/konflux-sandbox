# Kind operator and Tekton experiment

Date: 14 October 2026.
Prototype: P1, existing platform phase.
Outcome: the selected operator-managed components and an ordinary PipelineRun coexist successfully.

## Question and scope

Can a small Konflux installation host an ordinary workflow with a structured result outside normal build and release processing?

The experiment used a new Kind cluster with a dedicated kubeconfig.
It installed Tekton dependencies and three Konflux component resources through the existing operator.
It did not install a parent Konflux resource, UI, Build Service, or Release Service controller.
No GitHub App, model, or repository credentials were required.

The workload emitted a fixed synthetic verdict.
It established workflow and result transport behavior.
Actual check execution and remote sandbox dispatch remain later phases.

## Environment

| Item | Observed value |
| --- | --- |
| Cluster | konflux-sandbox-prototype |
| Context | kind-konflux-sandbox-prototype |
| Kind | v0.33.0 |
| Kubernetes | v1.37.0 |
| Kind node image | kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5 |
| Docker server | 29.9.0 |
| Konflux operator image tag | 858480e0f07ba58fc0f7ebb2cf2afaf11be85fb8 |
| Integration Service image tag | a5e72c8f7f38fef128feccdda1de53d99a6823f4 |
| Tekton Operator | v0.81.2 |
| Tekton Pipelines | v1.15.3 |
| Tekton Chains | v0.29.7 |
| Tekton Results | v0.20.0 |
| Pipelines-as-Code | v0.50.1 |
| Task image | docker.io/library/alpine:3.22.2@sha256:85f2b723e106c34644cd5851d7e81ee87da98ac54672b29947c052a45d31dc2f |
| Installed RuntimeClasses | 0 |

The installed versions form an observed experiment baseline.
They do not establish a supported extension version matrix.

## Operator resources and readiness

These resources reported Ready=True:

- KonfluxApplicationAPI/konflux-application-api.
- KonfluxIntegrationService/konflux-integration-service.
- KonfluxCertManager/konflux-cert-manager.

Application API readiness covers installed schemas.
Integration Service readiness covers its running controller deployment.
The TektonConfig basic profile also reported Ready=True.

## Installation dependency finding

Integration Service initially failed startup because ReleasePlan was absent.
After that schema was available, startup exposed the missing Release schema.
It recovered after both schemas were available.

Its Snapshot controller registers cache indexes for ReleasePlan and Release during startup.
These API dependencies exist even when the release controller is absent.

The experiment applied ReleasePlanAdmission conservatively before identifying the exact index requirements.
That third schema remains installed, but the observed startup failures identify ReleasePlan and Release as the required pair.

Sources: [Snapshot controller cache setup](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/internal/controller/snapshot/snapshot_controller.go#L208),
[release cache indexes](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/cache/cache.go#L31).

Decision: record schema dependencies separately from enabled controller deployments in the extension installation recipe.

## Native workflow observation

PipelineRun native-check ran in namespace sandbox-prototype.
Its first task emitted a string result containing JSON.
Its second task consumed that result through a Tekton parameter dependency.
The PipelineRun exposed the same result to the caller.

```json
{"schemaVersion":1,"outcome":"passed","check":"native-shape"}
```

The run started at 10:22:14 UTC and completed at 10:22:29 UTC.
That single execution took 15 seconds.
It does not establish cold startup or production check latency.

The task Pods used UID and GID 65532.
Their service account and Pod configuration disabled token automount.
The step configuration disabled privilege escalation and dropped Linux capabilities.

The run carried neither Konflux build nor integration-test type labels.
No Snapshot existed after execution.
The experiment contained no Application, Component, or ordinary build candidate.
The observation supports scoped coexistence without establishing every promotion path's behavior.

Source: [build and integration PipelineRun predicates](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/utils.go#L31).

Initial decision: test a versioned dispatch task and distinct workflow labels.
The later runtime experiment supports native VM TaskRuns for finite checks; the dispatch adapter remains optional.

## Runtime limits

The cluster had no RuntimeClass and no installed VM runtime.
The task Pods ran through ordinary Kind container execution.
Host KVM device availability did not establish VM support inside these nodes.

VM isolation, network bypass prevention, broker enforcement, checkpoint restoration, and independent execution receipts remain separate prototype questions.

## Local evidence and access

The retained evidence directory is:

```text
/tmp/konflux-sandbox-prototype-qw2Tu2
```

It contains the dedicated kubeconfig, Kind configuration, operator overlay, selected component resources, PipelineRun manifest, status snapshots, and setup logs.
EXPERIMENT.md records the exact setup commands and retained resources.
The [recorded public inputs](../setup/README.md) preserve the cluster, operator, component, and native workflow configuration.
Keep the kubeconfig private.
The directory is temporary and can disappear after host cleanup.

Inspect the retained workflow with explicit cluster selection:

```sh
kubectl --kubeconfig /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig \
  --context kind-konflux-sandbox-prototype \
  get pipelinerun native-check -n sandbox-prototype
```

The cluster remains available for follow-up experiments.
To remove this experiment cluster, use its dedicated kubeconfig:

```sh
KUBECONFIG=/tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig \
  kind delete cluster --name konflux-sandbox-prototype
```

## Next decisions

1. Add a throwaway execution endpoint and Tekton dispatcher for the next P1 phase.
2. Explore uncertain dispatch and cancellation through P2.
3. Establish canonical source identity through P3.
4. Evaluate a real VM runtime and its authenticated transport before claiming sandbox isolation.
