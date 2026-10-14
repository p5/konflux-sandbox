# Konflux Sandbox foundation implementation plan

Date: 14 October 2026.

Build a shared sandbox foundation that external services use for checks, workspaces, discovery, and investigation.
The [requirements](requirements.md) define the current scope.
The [architecture](architecture.md) defines module responsibilities and execution guarantees.
External services own product controllers, user interfaces, agent reasoning, findings, patches, review, and publication decisions.

## Prototype baseline

The [prototype findings](prototype-findings.md) record actual Konflux, Tekton, Agent Sandbox, Kata, artifact, policy, and Results behavior.
The [aggregate replay](experiments/010-aggregate-replay.md) completed successfully on the two dedicated Kind clusters.
Those experiments support native VM TaskRuns for finite execution and Agent Sandbox for session lifecycle.
The runtime choices remain subject to a supported compatibility contract.

The network experiment demonstrated one direct Pod IP restriction.
It did not establish domain allowlists, DNS rebinding protection, IPv6 coverage, or complete bypass prevention.
Domain and IP firewall enforcement is a required first-release capability.
Select its implementation and demonstrate its guarantees before claiming a supported foundation profile.

The investigation prototype remains a consumer example that informed execution and evidence requirements.
Its existence does not add a vulnerability product to this repository's scope.

## First working deliverable

A minimal client submits immutable source, an approved command definition, and an authorized execution profile.
The foundation records an attempt and starts a bounded command in a fresh VM guest.
It enforces domain and IP allowlists outside the guest.
It returns execution results, diagnostic references, artifact identities, enforcement evidence, and cleanup status.
A small check fixture demonstrates the interface.
External services can build check products against the same interface.

Acceptance requires these outcomes:

- Passing and failing commands return distinct outcomes with bounded diagnostic output.
- The receipt identifies the source, command definition, environment, execution profile, policy revision, owner, and attempt.
- The guest receives no upstream credentials or general Kubernetes API token.
- Approved domain and IP destinations work only on authorized ports and protocols.
- Unapproved destinations, protected destinations, and tested domain bypass paths fail.
- Firewall readiness gates command start, and enforcement failure stops affected network access.
- Policy revocation stops new connections and terminates existing connections within a documented bound.
- Cancellation and deadline expiry stop the workload.
- Cleanup removes execution resources and temporary storage according to the retention policy.
- Controller recovery adopts known resources and records uncertain execution without implicit command repetition.
- Exploratory executions do not automatically create release Snapshots or enter release processing.
- Another service can submit, observe, cancel, and retrieve evidence through the documented interface.

The first deliverable includes M0 through M3.
M4 adds credential grants.
M5 adds reusable session capabilities.
Consumer products remain outside these milestones.

## Milestones

| Milestone | Foundation deliverable | Completion evidence |
| --- | --- | --- |
| M0 | Runtime, firewall, transport, and dependency decisions | Exact versions, enforcement guarantees, deployment requirements, and actual compatibility evidence |
| M1 | Source identity, execution contract, profiles, and durable state | Immutable requests, owner authorization, explicit outcomes, attempt identity, and receipt schema |
| M2 | VM execution and outbound firewall | Source import, bounded commands, domain and IP enforcement, cancellation, deadlines, and cleanup |
| M3 | Konflux integration and minimal client | Complete first deliverable through documented interfaces and a native VM TaskRun |
| M4 | Credential broker | Scoped operations, execution identity, revocation, budgets, and exclusion of upstream credentials from guests |
| M5 | Session capabilities | Authorized attachment, command streaming, terminals, persistent files, export, and explicit restoration capabilities |
| M6 | Consumer integration contract | Client interfaces, capability discovery, compatibility documentation, and small external-service examples |
| M7 | Production hardening | Private evidence, audit, retention, issuer authority, failure recovery, and profile conformance |
| M8 | Optimization and upstream integration | Safe warm state, demonstrated checkpoint semantics, optional operator integration, and separate upstream contributions |

## M0 Select supported implementations

Record the VM runtime, CNI, firewall implementation, storage driver, and served API versions.
Pin compatible Agent Sandbox, Tekton, Kubernetes clients, and controller-runtime versions.
Use supported interfaces instead of imports from Konflux controller internals.

Select the firewall's deployment model before implementing its adapter.
Evaluate how domain rules authorize names, resolve addresses, handle shared IPs, and restrict supported protocols.
Record how enforcement covers native TaskRuns, sessions, broker operations, IPv4, and IPv6.
Define protected destination precedence, policy readiness, DNS expiry, revocation bounds, and failure behavior.
Keep enforcement outside untrusted guests.

Record required cluster privileges and any CNI or routing dependencies.
Reject profiles whose enforcement guarantees the installed implementation cannot provide.
Do not infer enforcement from configuration objects alone.

Select an authenticated transport for command, file, terminal, and log traffic.
The runtime experiment records Kata's direct port-forward limitation and the local TCP proxy workaround.
Production transport needs authenticated encryption and destination identity across guest replacement.

Select the extension API group and project license before the first implementation release.

## M1 Define foundation contracts

Define the minimum durable execution request and administrator-controlled execution profile.
Use the recovery prototype to choose an owned PipelineRun or a provisional execution resource.
Keep product resources such as WorkspaceSession, SecurityCampaign, and SecurityInvestigation in consumer repositories.

A request identifies immutable source, approved command definition, environment, profile, owner, request identifier, limits, and deadline.
The controller records resolved identities before execution.
An admitted request cannot expand its inputs or authority.
Each explicit retry receives a new attempt identity.

Separate execution outcome, infrastructure outcome, and cleanup status.
Record unknown outcomes when dispatch acknowledgement or result delivery is uncertain.
Repeated reconciliation must adopt the same owned child resources.
An orphan reconciler must remove expired resources after controller failure.

Define canonical source selection, filesystem metadata, confined import, output export, and bounded artifact formats.
Keep Git revisions as context until the foundation verifies their exact relationship to source bytes.
Define receipt fields and separate supervisor observations from guest-reported output.

Expose capability information for finite execution, sessions, storage, firewall features, and restoration semantics.
Consumers must detect unsupported operations before execution.

## M2 Implement VM execution and firewall enforcement

Allocate fresh guests from approved pinned environments.
Keep source scripts and target programs inside the guest.
Keep trusted control, artifact transport credentials, signing authority, and enforcement outside it.

Implement allocation, source import, command execution, bounded output, export, cancellation, and destruction.
Bind runtime resources and firewall state to the execution attempt.
Require enforcement readiness before untrusted commands start.

Implement the domain and IP firewall requirements from the requirements document.
Test allowed and forbidden domains, IPs, CIDRs, ports, and protocols.
Include controlled DNS, address expiry, rebinding, shared addresses, direct IP attempts, redirects, alternate resolvers, and protected destinations.
Cover IPv6 or disable it explicitly before admission.
Verify revocation against existing connections as well as new connections.
Verify enforcement failure and controller restart behavior.

The first profile can restrict network access to fixture destinations and required control or artifact transport paths.
It must still demonstrate domain and IP rule semantics.
A broad outbound allow rule cannot substitute for domain enforcement.

## M3 Expose the first foundation interface

Add one versioned native VM task and a minimal execution client.
The client imports source, submits execution, observes results, cancels execution, and retrieves evidence.
Another service must be able to use the same interface without constructing backend Pods or firewall resources.
Add remote dispatch only when a supported execution path requires it.

Preserve native Tekton step and result mechanics where compatibility evidence supports them.
Keep arbitrary TaskSpec translation outside the first deliverable.
Use separate labels and workflow definitions for exploratory execution.
Keep promotion into ordinary Konflux builds and releases under consumer authorization.

Expose artifact references, Results references, and execution evidence through documented contracts.
Configure log storage separately before promising archived logs.
Install the foundation through standalone manifests with scoped RBAC and explicit dependencies.

## M4 Add scoped credential operations

Deploy the broker with separate service accounts, permissions, and upstream credentials.
Bind grants to execution identity, owner, destination, operation, deadline, and budget.
Expose grant creation and revocation only to authorized callers.
Guests receive only the scoped identity required to request permitted operations.

Validate destinations, redirects, methods, and provider-specific operation scope before credential injection.
Apply destination policy to broker-originated traffic.
Revoke grants after cancellation, completion, expiry, or owner removal.
Keep credentials out of guest files, environment, process memory, logs, and receipts.
Consumer services own model selection, reasoning loops, repository publication, and product budget policy.

## M5 Expose session capabilities

Expose authorized command streaming, terminal attachment, file transfer, persistent files, and source export.
Reuse the shared profile, firewall, credential, identity, and evidence implementation.
Keep repository association, editor integration, workspace interfaces, and product session workflows in consumer services.

Record file persistence separately from process and VM memory restoration.
Expose restoration only through a capability that the selected runtime demonstrates.
Recheck authorization and firewall readiness when resuming a session.

## M6 Define consumer integration

Document submission, observation, cancellation, attachment, artifact, evidence, grant, and capability interfaces.
Publish client libraries only where they reduce repeated integration work.
Keep wire contracts versioned and document supported compatibility combinations.

Provide small finite-command and interactive-session examples.
Use fixtures instead of implementing workspace or vulnerability products.
Consumers own baseline comparison, finding classification, exploit reproduction, patch validation, review, and publication decisions.
The foundation supplies the isolated execution and evidence those decisions require.

## M7 Harden foundation guarantees

Implement private artifact and log access, retention, audit, issuer authority, and key lifecycle.
Keep sensitive workload details outside public Kubernetes events and public build status.
Verify cross-owner denial, resource exhaustion, partial cleanup, controller restart, and enforcement failure.
Document precisely which supervisor observations each receipt supports.
Use existing Konflux signing, policy, and archive interfaces where their trust contracts fit.

## M8 Optimize and contribute upstream

Add warm environments only after input, profile, and execution identity contracts are stable.
Do not reuse mutated tenant state as a shared base.
Bind warm state to approved environment, dependency, policy, and tenant identities.

Add checkpoint capabilities with explicit ownership, encryption, expiry, authorization, and firewall restoration rules.
Consumers own any policy for authoritative reuse of execution results.

Prepare separate upstream changes for reusable tasks, optional operator integration, lifecycle improvements, and policy interfaces.
Track unrelated upstream bugs in the [bug list](upstream-bugs.md).

## Planned code structure

```text
api/                         Foundation resources and generated schemas
cmd/manager/                 Execution and session lifecycle controllers
cmd/broker/                  Credential broker
cmd/ksbx/                    Minimal execution client
internal/execution/          Attempt state and resource lifecycle
internal/backend/            Runtime and session adapters
internal/firewall/           Resolved network policy and enforcement adapter
internal/artifacts/          Canonical source and confined transport
internal/evidence/           Receipts and trusted observations
internal/broker/             Grants and scoped operations
client/                      Consumer integration interfaces
tasks/                       Native VM tasks and optional dispatch adapters
config/                      CRDs, RBAC, profiles, and installation
examples/                    Small consumer fixtures
Makefile                     Local verification and demonstration targets
```

Create directories only when implementation requires them.
Keep each contribution on one topic.
Run all verification locally through Makefiles.
Do not add repository CI workflows.
