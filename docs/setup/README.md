# Recorded platform setup inputs

These public inputs preserve the first Kind experiment's configuration.
The kubeconfig and generated installation files remain private scratch state.

- kind.yaml defines the dedicated cluster without host port mappings.
- kustomization.yaml selects the pinned operator image from the sibling Konflux checkout.
- components.yaml selects certificate, API, and integration components.
- native-check.yaml defines the initial synthetic workflow.

The [first experiment](../experiments/001-kind-operator.md) records the observed versions and installation sequence.
Its retained EXPERIMENT.md contains the original setup commands and logs.
The operator overlay here uses a portable relative source path.

Render that overlay from the repository root:

```sh
kustomize build --load-restrictor LoadRestrictionsNone docs/setup
```

The initial setup ran the pinned Konflux deploy-deps.sh with these settings:

```text
SKIP_SMEE=true
SKIP_QUAY=true
SKIP_INTERNAL_REGISTRY=true
SKIP_CLUSTER_ISSUER=true
SKIP_KONFLUX_INFO=true
```

A temporary kubectl wrapper selected only the dedicated kubeconfig and context.
Keep that explicit selection when reconstructing the platform.

Integration Service also requires the ReleasePlan and Release schemas before startup.
The initial setup selected those schemas from operator/pkg/manifests/release/manifests.yaml in the pinned sibling checkout.
It also installed ReleasePlanAdmission conservatively.
The [lifecycle prototype](../../prototypes/konflux/Makefile) later installs the release and policy controllers it needs.

These files preserve installation inputs; they do not implement an automatic fresh-cluster installer.
The aggregate replay uses the retained dedicated clusters.
