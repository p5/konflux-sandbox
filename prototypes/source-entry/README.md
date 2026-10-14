# Local source-entry prototype

This prototype checks Build Service prerequisites and PaC source configuration without a Git provider account.
It also runs the resolved local fixture through Tekton.

Run from the repository root:

```sh
make -C prototypes/source-entry run
```

The command needs the sibling `build-service` and `pipelines-as-code` clones.
It also needs Go 1.27.1 or later, Node, jq, ripgrep, kubectl, and the dedicated prototype cluster.
Build commands can download pinned Go dependencies.

The Build Service harness imports actual controller code with an in-memory Kubernetes client.
It does not install the controller or watch cluster Components.
The local HTTP fixture captures the actual build-trigger payload and returns a denial.
It supplies no incoming secret.

The PaC CLI resolves local Tasks and template parameters without provider credentials.
An offline kubeconfig prevents the resolver from accessing the real cluster.
The parser command uses a temporary Go overlay to expose the actual private incoming parser.
The overlay adds only an export wrapper and a command entry point.
It does not change upstream files or parser logic.

The cluster stage submits the resolved synthetic pipeline in `source-entry-prototype`.
It uses a dedicated service account with token automount disabled.
It does not perform a Git checkout or emulate provider authorization.

Individual stages:

```sh
make -C prototypes/source-entry build-service
make -C prototypes/source-entry pac
make -C prototypes/source-entry cluster
```

Each stage runs its prerequisites.
Evidence resides in `.prototype-results/source-entry`.
See [the experiment report](../../docs/experiments/008-source-entry.md).

To remove the cluster resources, use the dedicated context:

```sh
kubectl --kubeconfig /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig \
  --context kind-konflux-sandbox-prototype delete namespace source-entry-prototype
```
