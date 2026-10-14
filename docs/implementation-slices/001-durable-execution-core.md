# Implementation assignment: durable execution core

## Objective

Implement the first durable core for the Konflux Sandbox foundation.
External services will use this foundation for checks, workspaces, discovery, and investigation.
This contribution covers M1 contracts and lifecycle control.
The next contribution connects an approved finite command through a real execution provider.

Kubernetes can store durable request state without restricting the execution provider to Kubernetes.
The provider interface must support a future remote service that manages Firecracker on dedicated EC2 instances.
Implement no Firecracker, EC2, cloud provisioning, or remote provider service in this assignment.

## Workspace and source material

Work only in /var/home/admin/Repos/konflux-ci/konflux-sandbox-core.
Use branch feat/durable-execution-core.
The branch starts from origin/main and excludes throwaway prototype code.
Preserve the separate planning worktree and prototype worktree.
Preserve all sibling research checkouts and existing clusters.

Read these local research documents before implementation:

- ../konflux-sandbox-prototypes/docs/requirements.md
- ../konflux-sandbox-prototypes/docs/architecture.md
- ../konflux-sandbox-prototypes/docs/implementation-plan.md
- ../konflux-sandbox-prototypes/docs/experiments/013-durable-lifecycle.md
- ../konflux-sandbox-prototypes/docs/experiments/017-consumer-recovery.md
- ../konflux-sandbox-prototypes/docs/experiments/018-guest-storage-limits.md
- ../konflux-sandbox-prototypes/docs/experiments/019-foundation-replay.md

Research baseline: prototype/integration-spikes, commit fb03209748bdaab40759b31a8649437c85cb59e4.
The [recorded architecture](https://github.com/p5/konflux-sandbox/blob/fb03209748bdaab40759b31a8649437c85cb59e4/docs/architecture.md) supplies supporting evidence.
This assignment takes precedence over older Kubernetes-only assumptions in that baseline.
Treat prototype code as evidence. Do not copy its host administration scripts into production code.

## Deliverables

1. Add a Go module and a minimal manager entry point.
2. Define versioned Execution and ExecutionProfile Kubernetes resources.
3. Add structural CRD schemas, generated code, and scoped installation RBAC.
4. Implement durable lifecycle reconciliation with a small provider interface.
5. Implement deterministic fake adapters for lifecycle verification.
6. Add local Makefile targets for generation, builds, static checks, and tests.
7. Document the interface, trust assumptions, state transitions, examples, and deferred integrations.

Use provisional API group foundation.sandbox.p5.dev and version v1alpha1 for this private implementation branch.
Keep resource names and group definitions centralized.
Record API group stabilization and license selection as release decisions.
Do not make an implementation release in this assignment.

## Resource contracts

An Execution represents one immutable request and one attempt.
A deliberate retry creates a new Execution with a new attempt identity.
Cancellation is monotonic. A caller cannot withdraw it.

The request identifies immutable source, an approved command definition, environment, profile, resource limits, and an absolute deadline.
Use source and environment references that can represent provider-supported artifact formats.
Keep source identity separate from contextual Git information.
Do not require a repository, Component, Snapshot, PipelineRun, Pod, RuntimeClass, or EC2 instance in the request contract.

ExecutionProfile holds administrator policy and provider selection.
Resolve the selected profile before allocation.
Persist the resolved configuration, profile identity, and policy revision before side effects.
Later profile edits cannot silently expand an admitted attempt's authority.
Validate digest syntax, deadline bounds, required capabilities, and requested resource ceilings.

Separate the authenticated owner from caller-supplied metadata.
Use Kubernetes authorization and scoped namespace access for this first control interface.
Define precisely how the controller derives owner authority under that model.
Never authorize access from spec.ownerID, a label, or a caller-supplied identity string alone.
Use admission controls or the namespace security model where Kubernetes RBAC cannot enforce field ownership.
Document the limits of that model and the later authenticated service interface.

Keep command outcome, infrastructure outcome, and cleanup state separate.
Status contains bounded conditions, attempt identity, resolved identities, allocation bindings, and diagnostic references.
Keep logs, source data, credentials, and private evidence bodies outside Kubernetes status and events.

## Provider interface

Place the provider interface beneath the execution module.
Keep reconciliation and policy resolution above that interface.
Keep provider-specific resource ownership, transport, and runtime operations inside adapters.

Use ordinary Go values in the provider interface.
Do not import Kubernetes, Tekton, controller-runtime, or foundation CRD types into that interface package.
Do not pass Kubernetes clients, Pod templates, TaskSpecs, kubeconfigs, or filesystem paths as universal provider requirements.
Represent resource limits in documented provider-independent units.
Support asynchronous operations and observation without requiring a long-lived caller process.
The interface must permit an adapter to call a remote authenticated service later.
Implement no RPC framework or plugin loader now.

Define the minimum operations for capabilities, allocation, observation, command admission, stop, and disposal.
Combine operations when this reduces caller knowledge without hiding failure semantics.
Record each operation's idempotency, lookup behavior, acknowledgement, and ambiguous failure modes.
Support durable lookup by request and attempt identity.
Do not require every provider to supply command deduplication.
Never assume exactly-once command execution or external side effects.

An allocation binding identifies the provider, opaque allocation ID, and allocation generation.
Bind it to the immutable request and attempt.
Keep optional adapter diagnostics separate from authoritative identity.
A Pod UID can be a diagnostic field. It cannot be the universal allocation identity.
An external provider must work without any Pod UID, node name, namespace, or RuntimeClass.

Distinguish desired policy from trusted provider observations.
Represent current allocation identity, enforcement readiness, absolute deadline, and allocation lease as execution admission facts.
Require readiness before untrusted source processing or command dispatch.
Reject unsupported capabilities and unavailable enforcement.
The default manager must not execute workloads through a permissive or fake provider.
Keep test adapters outside production installation paths.

Provider disposal observations must cover every allocation generation associated with the attempt.
A missing Kubernetes object, missing provider response, or stopped initial allocation alone cannot prove complete disposal.
Require explicit provider evidence for a terminal cleanup decision.
Document provider trust and evidence authority without claiming hardware attestation.

## Durable lifecycle rules

Persist allocation intent before requesting allocation.
Use provider lookup or documented allocation idempotency after an ambiguous allocation response.
Do not allocate a replacement blindly.
Persist the observed allocation binding before untrusted source processing or commands.

Persist command intent before dispatch.
After uncertain acknowledgement or result commit, record UnknownOutcome.
Do not dispatch that command again automatically.
Reject observations from another request, attempt, provider, allocation, or generation.
Adopt an existing allocation only after its complete binding and authority match.

Persist cancellation and propagate stop requests idempotently.
Apply the absolute deadline independently of scheduling or startup delay.
Reconcile expired requests after controller restart.
Define the provider's required local deadline and lease behavior during controller or API failure.
Do not claim that a controller timer alone enforces execution deadlines during its own outage.
Lease renewal cannot extend authority beyond the absolute deadline or restore revoked authority.

Hold the cleanup finalizer until trusted observations prove complete disposal.
Keep uncertain cleanup explicit and observable.
Cancellation, deletion, delayed success, and cleanup failures must not erase uncertainty or report false success.
Use conflict handling that prevents stale controllers from restoring authority or duplicating dispatch.
Distinguish Kubernetes status concurrency from provider admission fencing.
Carry an authority revision or lease identity in mutating provider operations where the contract needs fencing.
Document the provider's rejection rules for stale authority.
Do not claim that Kubernetes status updates alone fence external side effects.
Keep finalization correct when the provider is temporarily unavailable.

## Fake adapters and acceptance cases

The user explicitly authorized adding and running local automated tests through Makefiles.
Use the execution interface as the main behavior test interface.
Use a real local Kubernetes API where schema, admission, status, finalizers, or authorization require API behavior.
Do not treat a fake Kubernetes client as proof of API validation or RBAC.
Keep any Kubernetes test environment separate from unrelated clusters.

Provide one fake adapter with Kubernetes-style allocation diagnostics.
Provide another with remote VM allocation IDs and no Kubernetes fields.
Both adapters must exercise the same execution lifecycle without controller branches for a particular provider.
Keep the fakes small and deterministic. Simulate failures through explicit actions.

Verify these cases:

- Immutable request fields and one-way cancellation reject invalid updates.
- A consumer cannot modify administrator profiles or another owner's requests under the documented authorization model.
- Profile resolution fixes authority before allocation.
- Unsupported capabilities and missing enforcement prevent command dispatch.
- Duplicate reconciliation does not repeat allocation or command dispatch.
- Restart after allocation adopts the exact provider binding.
- Ambiguous allocation uses lookup or records uncertainty without replacement.
- A changed allocation generation fails adoption, including an unchanged Pod UID case.
- Command intent with uncertain acknowledgement or result commit becomes UnknownOutcome without replay.
- Cancellation and deadline expiry propagate stop requests and preserve independent cleanup status.
- Delayed success cannot reverse cancellation, expiry, or an uncertain command outcome.
- Stale authority cannot dispatch work or extend a revoked lease.
- Cleanup failure or missing disposal evidence retains the finalizer.
- Disposal checks account for every allocation generation.
- Provider unavailability cannot become successful cleanup.
- Both fake adapters pass the same provider-independent behavior cases.
- Production configuration cannot activate a fake provider or bypass execution admission.

These tests establish core behavior with simulated providers.
They do not establish real VM isolation, network enforcement, storage quotas, or API-independent runtime termination.

## Scope limits

Implement no real Kata, Firecracker, EC2, or Agent Sandbox allocation adapter in this contribution.
Implement no native TaskRun execution path yet.
Design the interface so the next contribution can add the native finite adapter without changing lifecycle rules.
The future external VM adapter remains an independent implementation.

Implement no workspace product, checks product, vulnerability workflow, model loop, or repository publication.
Implement no credential broker, domain gateway, node agent, or private object store in this contribution.
Define their required admission and observation contracts where the core needs them.
Keep unimplemented security capabilities unavailable by default.
Do not present requested policy, RuntimeClass selection, or Kubernetes storage settings as enforcement evidence.

Implement no checkpoint, warm snapshot, arbitrary TaskSpec translator, or Konflux operator integration.
Preserve existing Konflux APIs and workflows.
Add no repository CI workflow.

## Working rules and handoff

Read all applicable AGENTS.md instructions before editing.
Fetch origin and check branch status before the first edit.
Keep the branch based on the latest origin/main while it is clean.
Never update a dirty branch automatically.
Use the use-modern-go skill before Go edits.
Use ASD-STE100 prose and Conventional Commits.
Pin compatible dependencies from the recorded research where applicable.
Record any necessary version changes and their reason.

Start with a short implementation sequence and the proposed interface.
Send that outline to the parent, then continue implementation autonomously.
Prefer small modules with explicit failure semantics.
Keep generated files reproducible through Makefiles.
Run the authorized local tests and static checks.
Commit completed work locally in reviewable commits.
Do not push implementation commits or open a pull request before parent review.
Do not spawn additional agents for this assignment.

Report changed files, interface decisions, commands, results, limitations, and follow-up work.
Explain how an external Firecracker provider can implement the interface without Kubernetes execution objects.
Identify the next finite execution adapter contribution.
