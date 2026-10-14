# Konflux Sandbox implementation plan

Date: 14 October 2026.

Build an optional Konflux extension around one sandbox execution contract.
Deliver an isolated check before interactive workspaces or vulnerability automation.
Use that check to establish source identity, execution policy, results, and cleanup.

The [architecture](architecture.md) defines the shared contract and module responsibilities.
The resource names below are provisional.

## Architecture prototypes

The [prototype plan](prototypes.md) defines six bounded experiments and the decisions they inform.
Start with platform dispatch, execution recovery, and source identity before broad implementation.
Evaluate checkpoint semantics during runtime selection, even though full restoration follows the first deliverable.

Use Kind for operator and Tekton integration.
The [runtime experiment](experiments/004-runtime-lifecycle.md) demonstrated real Kata execution and tested network restrictions in a separate Kind cluster.
Use its direct VM TaskRun path for the first finite check unless another requirement needs remote dispatch.
Keep all prototype execution local through Makefile targets.
The [first Kind experiment](experiments/001-kind-operator.md) records the existing platform baseline and its installation dependencies.

## First working deliverable

A developer submits a local working tree and selects an approved check definition.
The extension exports immutable source and starts a Tekton workflow.
A native Tekton TaskRun requests a fresh guest through an approved RuntimeClass.
The check runs inside that guest.
The developer receives a structured verdict, log references, output digests, and cleanup status.

The first check uses a small fixture with all dependencies in a pinned environment image.
It needs no model, repository write access, or network access to package registries.
Trusted transport imports source and exports results without exposing registry credentials to the guest.

Acceptance requires these outcomes:

- A passing fixture returns a passing verdict.
- A changed fixture returns a failing verdict with bounded diagnostic output.
- The receipt identifies the exact source, check definition, environment, and execution profile.
- The guest has no upstream credentials or Kubernetes API token.
- A forbidden connection fails under the selected profile.
- Cancellation and deadline expiry stop the guest workload.
- Cleanup removes execution resources and temporary storage according to the retention policy.
- Controller recovery does not silently repeat an uncertain command.
- The check does not enter automatic Snapshot or release processing.

This deliverable includes milestones M0 through M3.
Credential access begins in M4.
Confidential vulnerability workloads require the additional controls in M7.

## Local verification

Run repository tests locally through a Makefile, as AGENTS.md requires.
Do not add repository CI workflows.
The product's Tekton tasks are separate from repository test automation.

Add these targets with the implementation they verify:

| Planned target | Scope | Required environment |
| --- | --- | --- |
| make test | Source identity, state transitions, authorization, and adapter contracts | Local development tools |
| make test-integration | Resource admission, reconciliation, and recorded child ownership | Local Kubernetes API environment |
| make test-conformance | Actual VM isolation, network restrictions, cancellation, and cleanup | Explicitly selected VM runtime and cluster |
| make demo-check | First working deliverable with passing and failing fixtures | Extension, Tekton, artifact storage, and supported backend |

Document each target's prerequisites and cleanup behavior.
Require explicit cluster selection for targets that create runtime resources.
Keep mock results separate from actual isolation evidence.

## Milestone sequence

| Milestone | Deliverable | Dependency | Completion evidence |
| --- | --- | --- | --- |
| M0 | Backend compatibility decision | Planning documents | Recorded versions, transport choice, hardware requirements, and runtime demonstration |
| M1 | Source identity and execution contract | M0 | Canonical source fixtures, immutable requests, explicit outcomes, and ownership rules |
| M2 | One isolated execution backend | M1 | Fresh guest execution, enforced profile, bounded results, cancellation, and cleanup |
| M3 | Tekton execution and check submission | M2 | Complete first deliverable through a CLI and Tekton PipelineRun |
| M4 | Credential broker | M3 | Restricted operations, execution identity, revocation, and secret exclusion |
| M5 | Workspace sessions | M4 | Authorized attach, persistent files, export, and check submission |
| M6 | One discovery adapter | M4 | Bounded campaign, structured findings, private evidence, and budget enforcement |
| M7 | Investigation and candidate promotion | M6 | Independent reproduction, candidate validation, review, and normal Konflux build handoff |
| M8 | Runtime optimization and upstream integration | Relevant earlier milestones | Proven checkpoint semantics, safe warm state, compatibility matrix, and separate upstream changes |

M5 and M6 can proceed independently after M4.
Each milestone produces a usable capability or a concrete compatibility decision.

## M0 Establish the backend and dependency baseline

Evaluate one Kubernetes backend with an existing VM runtime.
Use Agent Sandbox as the initial lifecycle candidate.
Record an alternative if it cannot meet the required execution contract.
Keep a mock backend for controller development.
Do not use a mock backend as isolation evidence.

Complete these tasks:

1. Select a Kubernetes or OpenShift environment with suitable virtualization hardware.
2. Record the VM runtime, CNI, storage driver, and installed API versions.
3. Pin compatible Agent Sandbox, Tekton, Kubernetes client, and controller-runtime versions.
4. Demonstrate guest creation, command execution, file transfer, and deletion.
5. Select an authenticated transport for the guest agent.
6. Confirm that network policy blocks direct bypass and cloud metadata access.
7. Record the installation method and minimum cluster permissions.
8. Select the extension API group and project license before the first implementation release.

The inspected Agent Sandbox and Konflux repositories use different Kubernetes client and controller-runtime versions.
Those library versions do not establish server compatibility.
Avoid dependencies on Konflux controller internals.
Validate the chosen served APIs and client combination explicitly.

The inspected Agent Sandbox SDK warns about direct sandboxd Pod port-forward access with Kata and gVisor.
Evaluate service-based connectivity with per-execution authentication.
A Service address alone does not authenticate the destination guest.

Agent Sandbox suspension currently deletes its backing Pod.
Record file persistence separately from process or VM restoration.
Full memory restoration is outside the first deliverable.

Output: a backend decision with exact versions and demonstrated capabilities.
M0 blocks claims of a supported isolated backend until that evidence exists.

## M1 Define inputs and execution state

Use Go and controller-runtime for the controller implementation.
Select the supported Go release when scaffolding starts.
Keep the runtime adapter behind the execution interface.
Start with one real adapter.

Define an administrator-controlled ExecutionProfile and the minimum durable execution request.
Use the recovery prototype to choose an owned PipelineRun or a provisional SandboxExecution resource.
Keep CheckRun, WorkspaceSession, SecurityCampaign, and SecurityInvestigation schemas outside this milestone.
Add each resource when its lifecycle needs durable state beyond existing resources.

The execution request contains:

- An immutable source reference and canonical source digest.
- A pinned check definition and environment identity.
- An approved execution profile reference.
- Resource limits, an absolute deadline, and output limits.
- An authenticated owner and a caller request identifier.

The controller resolves configuration once and records the resolved identities.
Execution parameters become immutable after admission.
The client cannot select arbitrary Kubernetes service accounts, host mounts, secrets, or execution templates.

Define explicit outcomes for success, check failure, infrastructure failure, cancellation, timeout, and unknown execution outcome.
Track cleanup independently from the check verdict.
A successful check with incomplete cleanup remains operationally incomplete.

Use deterministic child resource identity for repeated reconciliation.
Record a separate attempt for each explicit retry.
If dispatch outcome is uncertain, record that uncertainty and stop the attempt.
Do not claim exactly-once command execution across an unrecorded dispatch failure.

For source export, include tracked files and explicitly selected untracked files.
Exclude Git internals, sockets, device files, and configured sensitive paths.
Define stable path ordering, file modes, symlink rules, size limits, and metadata normalization.
Compute identity over a canonical manifest.
Keep a Git revision as context until the extension verifies an exact source relationship.

Output: resource schemas, state transitions, canonical source format, and receipt format.
Define verification fixtures for archive traversal, symlink escape, source changes, and oversized inputs.

## M2 Implement isolated execution

Create fresh guests from a pinned approved environment.
Run source processing and check commands inside the guest.
Keep the execution controller and trusted artifact transport outside it.

Implement these capabilities through the execution interface:

- Admission with an authorized profile and bounded resources.
- Guest allocation and authenticated connection.
- Confined source import and output export.
- Command execution with bounded logs and an explicit exit result.
- Deadline enforcement and cancellation.
- Trusted execution metadata and cleanup status.

The initial profile denies general outbound network access.
Permit only the specific transport paths required by the implementation.
Enforce those paths outside the guest.
Block metadata endpoints, unrelated cluster services, host access, and cross-execution access.

The controller checks runtime and enforcement readiness before admission.
If enforcement is unavailable, reject execution.
Do not fall back to a weaker runtime.

Keep the guest agent as a command and file transport.
Its reported test results remain untrusted workload output.
The external supervisor records guest identity, runtime configuration, policy readiness, and resource lifecycle.
Do not present requested configuration as independent proof of every runtime property.

Define the conformance workloads for lifecycle failures, authorization failures, and network bypass attempts.
Record which properties require external runtime evidence.

## M3 Integrate Tekton and a local client

Add a versioned native VM check pipeline under tasks/.
Reuse ordinary task steps and results where the runtime experiment established compatibility.
Add a dispatch task only for an execution path that needs the remote interface.
The dispatch task forwards cancellation and uses a bounded deadline.
Its credentials authorize only the required extension operations.

Start with one explicitly supported check shape.
Do not translate arbitrary Tekton TaskSpecs in this milestone.
Add support for step images, sidecars, workspaces, and result semantics through separate compatibility work.

Add a CLI that exports source, submits a check, observes progress, and cancels execution.
Use the same execution interface for the CLI and Tekton adapter.
Keep shell streaming outside Kubernetes status fields.

Use extension-specific labels and workflow definitions.
Do not mark exploratory PipelineRuns as normal Konflux builds.
Confirm that existing Snapshot predicates do not select these runs.

Install the extension through standalone Kustomize manifests.
Document required dependencies and supported versions.
Keep Konflux operator integration for a later milestone.

Complete the first deliverable with passing, failing, cancelled, timed-out, and recovery scenarios.
Store the resulting execution evidence and compatibility record.

## M4 Add the credential broker

Deploy the broker with separate service accounts, permissions, and upstream credentials.
Give execution guests only the identity needed to request an authorized operation.
Bind grants to the execution UID, owner, destination, operation, deadline, and budget.

Start with one model proxy operation and one fixed artifact destination.
Add repository fetch and publication operations separately.
Use Octo STS where GitHub federation meets the required trust policy.

Reject credential selection supplied by a guest.
Validate redirects, destination changes, request methods, and repository scope.
Prevent direct network bypass around the broker.
Revoke grants on cancellation, completion, expiry, and owner removal.

Keep upstream credentials out of guest files, environment variables, process memory, logs, and receipts.
An allowed model destination can still receive source data.
Profile authorization must cover that disclosure as well as credential access.

## M5 Add workspace sessions

Reuse the execution backend and profile enforcement.
Add owner authorization, repository association, interactive access, file persistence, and source export.
Run authoritative checks against immutable exports in fresh guests.

Start with file persistence and explicit process restart.
Expose process restoration only when the backend supports and demonstrates it.
Do not label file persistence as a full VM checkpoint.

## M6 Add one bounded discovery adapter

Start with OSS-Fuzz-gen or another approved harness for a small source target.
Pin the harness and tool images.
Define target scope, compute limits, model limits, deadline, and finding schema.
Keep generated commands, target code, and any nested container daemon inside approved isolation.
Do not expose the host Docker socket.

The campaign controller owns admission, attempts, budgets, cancellation, and finding collection.
The harness owns its inner reasoning and fuzzing loop.
Only one module owns retries for each recorded attempt.

Store source, crashes, reproduction inputs, logs, and model traces in private storage.
Keep sensitive details outside Kubernetes events and public CI status.

## M7 Add investigation and promotion

Establish a baseline before patch generation.
Reproduce each finding in a fresh validation guest.
Validate the same reproduction input against each candidate.
Compare regression results with the baseline.
Record infrastructure failures as inconclusive.

Group related findings and record target versions explicitly.
Require an authorized review before publication or patch promotion.
Publish an approved source candidate through the normal Git build path.
Use existing Konflux build, integration, and release workflows for the final artifact.

Extend Conforma policies for the required execution evidence.
Keep the trusted receipt issuer and signing material outside guests.
Keep confidential evidence outside public registries and transparency publication.

## M8 Optimize execution and prepare upstream contributions

Add warm environments only after source and execution identities have a stable contract.
Bind warm state to environment, dependencies, profile, and tenant policy.
Never reuse mutated tenant state as a shared base.
Invalidate warm state after relevant tool, dependency, or policy changes.

Add full process or VM checkpoints through an explicit backend capability.
Define checkpoint encryption, ownership, expiry, and credential grant renewal.
Recheck policy and authorization before restoration.

Keep before-push verdicts advisory until equivalence rules support authoritative reuse.
Those rules include source, check definitions, tools, dependencies, runtime, policy, target context, and freshness.

Prepare separate upstream changes for reusable catalog tasks, operator installation, lifecycle improvements, and policy support.
Each contribution needs a compatibility statement and evidence for its changed behavior.

## Planned code structure

```text
api/                         Extension resources and generated schemas
cmd/manager/                 Execution and workflow controllers
cmd/broker/                  Credential broker
cmd/ksbx/                    Local client
internal/execution/          Execution state and lifecycle
internal/backend/            Agent Sandbox adapter
internal/artifacts/          Canonical source and confined transport
internal/evidence/           Receipts and trusted metadata
internal/broker/             Grants and restricted operations
internal/workspaces/         Workspace lifecycle
internal/investigations/     Campaign and finding lifecycle
tasks/                       Versioned Tekton check tasks and optional dispatch adapters
config/                      CRDs, RBAC, profiles, and installation
examples/                    Bounded check and investigation fixtures
docs/                        Architecture and compatibility records
Makefile                     Local verification and demonstration targets
```

Create directories as implementation requires them.
Keep product workflows independent from backend-specific resource details.
Use supported remote interfaces instead of imports from Konflux controller internals.

## Immediate contribution sequence

| Change | Scope | Completion condition |
| --- | --- | --- |
| Planning | README, architecture, implementation milestones | Reviewable scope and first deliverable |
| Backend decision | Version matrix, runtime transport, environment requirements | M0 evidence resolves implementation dependencies |
| Architecture prototypes | Platform dispatch, execution recovery, source identity, and checkpoint capability records | Experiments resolve the relevant contract questions |
| Execution foundation | Go module, schemas, source identity, controller state | M1 contract supports one recorded attempt |
| Isolated backend | Allocation, command transport, artifacts, cancellation, cleanup | M2 profile meets its required conformance checks |
| First check | Tekton task, CLI, installation, fixture | M3 completes the first working deliverable |

Keep each change on one topic.
Record unresolved backend requirements before their dependent implementation starts.
