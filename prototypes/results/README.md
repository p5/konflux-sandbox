# Results archival and diagnostics prototype

This prototype checks actual Tekton Results records, namespace authorization, and failure diagnostics.
It also checks whether the installed Results API can return logs.

Run from the repository root:

```sh
make -C prototypes/results run
```

The command needs the dedicated Konflux prototype cluster with Tekton Results 0.20.0 installed.
It also needs kubectl, curl, jq, Node, yq, ripgrep, and the sibling `agent-plugins` and `tekton-results` clones.
The Results clone must contain the `v0.20.0` tag.

The command creates a synthetic failed PipelineRun in `results-prototype`.
It queries actual Results records with a namespace-scoped reader service account.
It requests a ten-minute TokenRequest credential for the trusted local client.
It stores the authorization header in an ignored file with private permissions.
It removes that file on exit and never prints its contents.
The guest tasks receive no service account token.

The command compares archived objects with live Kubernetes objects.
It runs the upstream diagnostic script against a cache built from the archived records.
It then deletes the live PipelineRun and confirms that its archived record remains available.

The installed profile has `LOGS_API=false`.
The prototype records HTTP 404 for Results log requests.
Its separate live Kubernetes log capture does not establish archived log retrieval.

The command changes no global Results, operator, signing, or release configuration.
It leaves the reader service account and its narrow RBAC in `results-prototype`.
It deletes its live PipelineRun after it records the evidence.

To remove the remaining namespace:

```sh
kubectl --kubeconfig /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig \
  --context kind-konflux-sandbox-prototype delete namespace results-prototype
```

Namespace deletion does not establish deletion of archived database records.
Results retention remains a separate policy.

See [the experiment report](../../docs/experiments/009-results-diagnostics.md).
