# Konflux Sandbox

Konflux Sandbox is a proposed extension for isolated checks, developer workspaces, and vulnerability investigations.
Each workflow uses one sandbox execution contract.
Konflux supplies workflow orchestration, artifact transport, policy evaluation, and release integration.

Status: executable architecture prototypes. The production extension remains unimplemented.

## Start here

- Read the [implementation plan](docs/implementation-plan.md) for milestones and acceptance criteria.
- Read the [architecture](docs/architecture.md) for module responsibilities and execution guarantees.
- Read the [prototype plan](docs/prototypes.md) for experiments that resolve architecture decisions.
- Read the [prototype findings](docs/prototype-findings.md) for observed integration behavior and implementation decisions.

The first deliverable runs one check against an immutable export of a local working tree.
It returns structured results and destroys the execution environment.
Repository credentials and model credentials stay outside the guest.

```text
working tree -> immutable source -> Tekton task -> sandbox execution
                                                   |
                                                   v
                                      results, evidence, cleanup
```

## Development approach

Build an optional extension in this repository before upstream integration.
Use supported Kubernetes and Tekton interfaces.
Keep existing Konflux build and release workflows compatible.
Run repository tests locally through a Makefile.
Keep repository CI workflows outside the implementation scope.

Start with one Kubernetes backend and an existing VM runtime.
Evaluate Agent Sandbox for lifecycle management during the compatibility milestone.
Add credential access through a separate broker after the first check works without upstream credentials.

Workspace sessions and vulnerability workflows follow the same execution implementation.
Full VM restoration, warm snapshots, and check-result reuse follow later milestones.

## Repository structure

Prototype code lives under prototypes/ on branch prototype/integration-spikes.
It is throwaway research code.
The implementation plan defines the future production code structure.

## Run prototypes

Run local state, broker, and investigation scenarios:

```sh
make prototype-local
make prototype-validate
```

Run the live prototypes against the dedicated local clusters:

```sh
make prototype-artifacts
make prototype-konflux
make prototype-dispatch
make prototype-runtime
make prototype-vm
make prototype-composed
make prototype-source-entry
make prototype-results
```

The live prototypes require the sibling upstream checkouts documented in their experiment reports.
The [recorded platform inputs](docs/setup/README.md) preserve the initial cluster and operator configuration.
They use dedicated kubeconfigs and synthetic workloads.
The default Konflux kubeconfig is /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig.
Override PROTOTYPE_KUBECONFIG explicitly when that private file moves.
Use `make prototype-all` for the complete sequence after cluster prerequisites are available.

Results and private scratch state stay in ignored directories.
Do not commit kubeconfigs or signing material.
