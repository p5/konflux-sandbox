# Konflux Sandbox prototype findings

Date: 14 October 2026.

Executable prototypes cover the local source-entry, execution, artifact, integration, evidence, runtime, credential, and investigation interfaces.
The results support an optional Konflux extension with a shared execution contract.
Native VM TaskRuns provide a smaller first implementation than a general remote task translator.

The current [foundation requirements](requirements.md) limit implementation to shared execution capabilities for external product services.
Workspace and vulnerability product controllers remain outside repository scope.
The new foundation experiments exercise domain and IP enforcement, real execution identity, durable recovery, private evidence, and external consumers.

The [revision inventory](prototype-revisions.tsv) records the inspected source baseline.
The experiment reports distinguish actual upstream behavior from proposed extension rules.
The [initial aggregate](experiments/010-aggregate-replay.md) records the eleven-target baseline.
The [foundation replay](experiments/019-foundation-replay.md) records the expanded twenty-target sequence and resource checks.

## Prototype inventory

| Target | Exercised interface | Evidence |
| --- | --- | --- |
| make prototype-source-entry | Actual Build Service prerequisites and incoming request; actual PaC resolution and parser; resolved Tekton run | [Source entry](experiments/008-source-entry.md) |
| make prototype-results | Authenticated Results archival, record persistence, and actual diagnostics from archived run data | [Results](experiments/009-results-diagnostics.md) |
| make prototype-konflux | Chains, build-to-Snapshot processing, integration semantics, and managed release entry | [Konflux lifecycle](experiments/002-konflux-lifecycle.md) |
| make prototype-artifacts | Canonical working tree, actual OCI helpers, actual producer policy, and proposed signed receipt validation | [Artifacts and evidence](experiments/003-source-artifacts-policy.md) |
| make prototype-runtime | Sandbox lifecycle, authenticated command transport, claims, and tested network restriction | [Runtime](experiments/004-runtime-lifecycle.md) |
| make prototype-vm | The same lifecycle in real Kata guests, plus native Tekton steps inside a VM | [VM execution](experiments/004-runtime-lifecycle.md) |
| make prototype-composed | Actual OCI source fetch, verified import, checks, and structured results inside a Kata TaskRun | [Composed execution](experiments/004-runtime-lifecycle.md) |
| make prototype-dispatch | Local client and real Tekton task using one asynchronous endpoint; active cancellation | [Dispatch](experiments/005-dispatch-recovery.md) |
| make prototype-recovery | Proposed attempt, cancellation, uncertain dispatch, and cleanup state | [Recovery](experiments/005-dispatch-recovery.md) |
| make prototype-broker | Actual local HTTP proxy with synthetic identity, grants, redirects, revocation, and budgets | [Broker](experiments/006-broker-grants.md) |
| make prototype-investigation | Baseline, reproduction, candidate, regression, missing evidence, and publication decisions | [Investigation](experiments/007-investigation-contract.md) |
| make prototype-firewall | Outside-guest domain/IP enforcement, DNS handling, revocation, and failure cleanup | [Firewall](experiments/011-firewall-enforcement.md) |
| make prototype-identity | Actual Kata mTLS transport, scoped identity, broker revocation, and guest replacement | [Identity](experiments/012-identity-transport.md) |
| make prototype-durable | Kubernetes-backed attempt recovery, cancellation, absolute deadlines, and verified disposal | [Durability](experiments/013-durable-lifecycle.md) |
| make prototype-guardian | API-independent allocation expiry and observation of kubelet replacement | [Durability](experiments/013-durable-lifecycle.md) |
| make prototype-private-evidence | Owner access, streamed logs, supervisor signatures, and fixed retention | [Private evidence](experiments/014-private-evidence.md) |
| make prototype-consumers | Token-free finite and session clients sharing one foundation interface | [External consumers](experiments/015-external-consumers.md) |
| make prototype-broker-network | Actual guest identity, operation grant, broker egress profile, and bounded network failures | [Broker network](experiments/016-broker-network.md) |
| make prototype-consumer-recovery | Exact TaskRun and Sandbox adoption; acknowledged command uncertainty without replay | [Consumer recovery](experiments/017-consumer-recovery.md) |
| make prototype-storage | Actual guest write limits, privilege drop, namespace bypass, and filtered enforcement | [Storage limits](experiments/018-guest-storage-limits.md) |

Run `make prototype-local` for the state, broker, and investigation scenarios.
Run `make prototype-validate` for static checks and documentation links.
Run `make prototype-all` for the complete sequence after the documented cluster prerequisites exist.
All commands run locally through Makefiles.
No repository CI workflows are required.

## Execution architecture decision

Use one approved VM runtime and one execution profile contract across checks and workspaces.
Use native Tekton TaskRuns for finite checks where they preserve required behavior.
Use Agent Sandbox for interactive sessions, storage, and warm-pool claims.
Keep a remote dispatch adapter for execution paths that require it.

The composed check consumed actual source through the existing OCI helper inside Kata.
Two ordinary Tekton steps also shared the same real guest kernel.
These observations remove the need to translate every existing task into remote tool calls.

The extension still needs shared authorization, canonical source identity, credential grants, enforced profiles, and trusted execution receipts.
Selecting RuntimeClass alone does not supply those responsibilities.

## Integration constraints

Source submission and Git source identity are different contracts.
The current incoming build request identifies a repository, branch, and PipelineRun definition.
An uploaded working tree needs an immutable source identity and an explicit relationship to Git context.

The Trusted Artifact helper identifies an archive blob separately from its OCI manifest.
The extension must preserve both identities where provenance refers to the manifest subject.
The helper's archive digest includes tar metadata, and restoration can retain stale destination files.
Use canonical source identity and a fresh import destination.

Kubernetes creates declared step working directories before preceding steps execute.
The composed experiment initially failed because a later workingDir made the intended fresh destination exist early.
Create the import destination explicitly, then enter it during command execution.

The current Integration Service requires ReleasePlan and Release schemas even without the release controller.
Treat installed schemas and enabled controllers as separate dependency lists.

The pinned Integration Service skips correctly new-labelled build PipelineRuns before Snapshot creation.
The live legacy Application and Component path created Snapshots successfully.
API schema availability therefore does not establish active support for every new-model execution path.
Pin the supported model and labels in the first extension compatibility contract.

## Result and recovery decisions

Keep raw Tekton outcomes and semantic integration outcomes.
A successful PipelineRun does not establish a passing integration test.
Integration Service also requires its structured TEST_OUTPUT contract.
The live experiment recorded a cancelled integration as TestFail, while the underlying run retained Cancelled.

Results preserved PipelineRun and TaskRun records after live PipelineRun deletion.
The existing diagnostic script identified a failed step from Results-derived records.
Structured archival and log storage need separate configuration.
The installed Results service disabled its log API; those log requests returned 404.

An extension needs explicit cancellation, timeout, infrastructure, and unknown outcomes.
Record an independent cleanup condition.
Never turn uncertain dispatch or missing evidence into a passing result.
An explicit retry receives a new attempt identity.

The dispatch task forwarded cancellation in the tested signal path.
A node or dispatcher crash can bypass that handler.
Keep authoritative cancellation and deadlines outside the task that can disappear.

## Managed release decision

Release Service created a managed PipelineRun from a controller-created Snapshot and the fixture's release admission resources.
Real Conforma signature and selected upstream policy checks permitted the local no-op destination.
A different allowed-predicate rule rejected the same signed artifact before that destination step ran.
Release status distinguished successful managed processing from policy failure.

The fixture used a namespace-local pipeline through explicit temporary debug mode.
With debug disabled, Release Service rejected that source before it created the managed PipelineRun.
Production integration needs an approved immutable pipeline source and the required production policy set.
The prototype did not publish an artifact externally.

Keep patch generation outside release credentials.
Promote only an approved immutable candidate and its required evidence into this existing managed release flow.

## Runtime and workspace decisions

Kata booted real guests on this machine after node-local DBus and shared-memory configuration.
The guest kernel differed from the node kernel.
No host service or kernel-module changes were required for this experiment.

Agent Sandbox suspension deleted the Pod, preserved files on its PVC, and lost process handles.
Warm-pool claims adopted a running Pod and replenished capacity.
Neither behavior establishes suspended VM memory snapshots.

Direct Pod port-forward worked for ordinary containers and failed for the Kata guest ports.
A dedicated TCP proxy preserved authenticated REST and streaming gRPC in the prototype.
The identity prototype added mTLS with external authorization, guest server verification, and current Pod UID binding.
It rejected old identities after actual guest replacement and interrupted revoked streams within three seconds.
Production still needs authorized enrollment, rotation, and durable identity state.

The tested KindNet enforced a direct Pod egress restriction for ordinary and Kata clients.
Other destination classes and bypass mechanisms need profile-specific conformance checks.
Do not infer enforcement from the presence of a NetworkPolicy object.

## Trust and credential decisions

Actual Chains signatures and attestations passed public-key verification.
An actual denied registry write exhausted Chains' default retries and produced signed=failed.
The successful Tekton build still caused Snapshot creation.
Public-key verification then rejected the unsigned artifact.
Snapshot existence and Chains completion therefore do not establish a trusted artifact.
Actual Conforma producer rules rejected missing and untrusted producers in their fixture graph.
These checks authenticate and evaluate claims.
They do not independently observe remote execution.

The proposed receipt verifier binds the request, attempt, source, check, environment, profile, issuer, and freshness.
It rejects guest issuers and dispatcher impersonation in its synthetic signing scenarios.
A supervisor signature still depends on the supervisor's actual enforcement and authority.

Keep the credential broker separate from guests and ordinary task permissions.
The local broker prototype enforces operation scope and concurrent request budgets.
Revocation stops an active upstream request.
The later identity experiment supplies real scoped certificates, encrypted transport, and active grant revocation.
Provider accounting and a production broker remain implementation work.
The consumer composition applies the shared outside-guest fence to command transport and workload traffic.

## Local provider boundary

The user selected local prototypes without a GitHub App.
No GitHub App credentials, provider actions, PRs, or external publication were required.
Build Service prerequisite scenarios use an in-memory Kubernetes client with actual upstream reconciliation code.
The PaC parser and resolver scenarios use actual upstream code.
The resolved fixture also ran through the real local Tekton installation.

GitHub webhook delivery, installation token federation, provider permissions, and PR result publication remain outside that selected scope.
The prototype does not treat local parser acceptance as proof of those external operations.

## Upstream contribution candidates

Two observed issues have small independent contribution scopes:

1. Parse OCI image references without truncating a registry port during Snapshot construction.
2. Return the HTTP transport error from TriggerPaCBuild when incoming delivery fails.

The lifecycle and source-entry reports preserve the exact code locations and reproductions.
The [upstream bug list](upstream-bugs.md) collects reproduction commands and suggested regression cases for separate contributions.
Other findings describe integration semantics or missing extension capabilities rather than established upstream bugs.

## Foundation decisions

Use one foundation interface above native finite TaskRuns and Agent Sandbox sessions.
External consumers receive scoped client identities rather than Kubernetes credentials or backend templates.
The foundation owns source import, profiles, allocation, firewall installation, transport, evidence, and disposal.

Use an outside packet fence with a trusted gateway for the first network profile.
Inspected HTTP/S permits domain guarantees; opaque TCP grants authorize explicit IPs and ports.
Controlled DNS and protected-address checks apply after resolution.
Reject unsupported protocols and retain enforcement until allocation disposal is verified.
The broker composition applies operation-grant permissions and the resolved destination profile before credential injection.
Its outside fence blocks direct origin access, and gateway loss fails closed.

The tested Kata setup accepted sixteen MiB writes despite eight MiB memory and disk emptyDir settings.
An explicit guest tmpfs enforced eight MiB; capability removal alone still permitted a user namespace mount bypass.
The filtered launcher blocked that tested bypass.
Storage guarantees need actual runtime and volume enforcement, including every writable path.

Persist immutable request fields and attempt identity in a small Execution resource.
Adopt known owned children after controller restart.
Record UnknownOutcome instead of silently repeating uncertain commands.
Retain the cleanup finalizer when allocation binding or disposal is uncertain.
Use an independent watchdog and a runtime supervisor with allocation admission fencing.
The guardian stopped an actual Agent Sandbox VM, after which kubelet created another VM under the same Pod UID.
Its synthetic entrypoint ran again. This does not demonstrate sandboxd API-command replay.
Bind certificates, grants, and admission to the provider allocation ID or generation as well as Pod UID.
The consumer recovery experiment separately adopted exact TaskRun and Sandbox allocations without startup or command replay.
Acknowledged but uncommitted checks became UnknownOutcome and underwent verified disposal.

Keep private logs and artifacts outside execution namespaces.
Bind signed receipts to actual supervisor observations and stored content digests.
Treat guest output as workload claims and signer authority as an explicit trust dependency.
The in-memory evidence fixture demonstrates access and retention semantics, not durable production storage.

## Remaining production work

Prototype evidence does not establish complete tenant isolation or production readiness.
Production work includes supported admission, durable controllers, a node supervisor, issuer lifecycle, private object storage, broker adapters, and runtime conformance.
The prototype code demonstrates selected behavior; it does not supply production services.
Full process restoration, warm snapshot safety, and authoritative reuse of before-push results need separate implementation.

The first production deliverable remains one immutable-source check with explicit identity, bounded execution, structured results, and verified cleanup.
That check becomes a minimal foundation fixture rather than a product implementation.
Its acceptance now also requires domain and IP firewall conformance.

## Resource ownership

The Konflux cluster is konflux-sandbox-prototype.
Its private kubeconfig is /tmp/konflux-sandbox-prototype-qw2Tu2/kubeconfig.
The separate VM cluster is konflux-sandbox-vm-prototype.
Its private kubeconfig is /tmp/konflux-sandbox-runtime/vm-kubeconfig.

The local registry and its portless proxy use the Docker kind network without published host ports.
Experiment reports name retained resources and cleanup commands.
Kubeconfigs, runtime captures, signing material, and scratch output remain outside committed artifacts.
