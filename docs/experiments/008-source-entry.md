# Local source-entry integration and GitHub boundary

Date: 2026-10-14.

## Question

Which source-entry steps can the extension reuse without a configured Git provider?
Which steps require provider authority and remain outside this local experiment?

## Execution and scope

```sh
make -C prototypes/source-entry run
```

The command completed all local controller, resolver, parser, and Tekton scenarios.
The [prototype](../../prototypes/source-entry/README.md) contains runnable code and cleanup instructions.

| Component | Version or revision |
|---|---|
| Build Service source | `ab6a21c3186fef99888269756ae8c36ad0155b38` |
| Build Service Application API dependency | `v0.0.0-20260727123715-2999a91451c6` |
| Build Service PaC dependency | `v0.43.0` |
| Standalone PaC source | `81817032ba22f09db838d264fa16acc0775dc2b5` |
| Go compiler | `go1.27.2 linux/amd64` |
| Task image | `alpine:3.22.2@sha256:85f2b723e106c34644cd5851d7e81ee87da98ac54672b29947c052a45d31dc2f` |

The harness preserves Build Service's dependency versions.
The standalone PaC CLI uses its cloned vendor directory.
These are distinct builds; the experiment does not establish compatibility between every PaC version and Build Service.

Build Service does not run as a cluster controller in this experiment.
Its actual controller code runs against an in-memory Kubernetes client.
The experiment creates no GitHub App, provider token, private key, webhook, pull request, or provider-side object.

## Actual Build Service prerequisites

The harness calls the new-model `ComponentBuildReconciler.Reconcile` method.
Each scenario starts with a separate in-memory Component and empty secret inventory.

| Input | Observed `status.message` |
|---|---|
| Empty Git source | `Nothing to do for component without git source; gitURL: ` |
| Git source without an output image | `waiting for spec.containerImage to be set (often by ImageRepository with annotation build.konflux-ci.dev/update-component-image)` |
| GitHub source without provider configuration | `Failed to get webhook data and PaC secret: 50: Pipelines as Code secret does not exist` |
| Unknown provider host | `Failed to get webhook data and PaC secret: 60: unknown git provider of the source repository` |

All four scenarios ensure one build service account and one role binding before stopping.
None creates a PaC Repository.
Each reconcile returns no error and no requeue after it records its persistent status message.
Callers must inspect the Component status; a nil reconcile error does not establish onboarding success.

The empty-source scenario bypasses API admission through the in-memory client.
It demonstrates controller behavior, not acceptance of an invalid Component by Kubernetes.
This experiment does not exercise watches, caches, admission, or installed controller RBAC.

Direct `GetPacSecrets` execution returns a persistent `BuildOpError` with ID `50`.
Its raw error is ` Pipelines as Code secret not found in build-service `.
The credential lookup checks matching namespace SCM secrets before it checks the global GitHub App secret.
The global secret name is `build-service/pipelines-as-code-secret`.

Direct trigger preparation without a PaC Repository returns:

```text
PaC repository not found for component local-source
```

Source hooks: [reconcile](https://github.com/konflux-ci/build-service/blob/ab6a21c3186fef99888269756ae8c36ad0155b38/internal/controller/component_build_controller_v2.go), [secret lookup](https://github.com/konflux-ci/build-service/blob/ab6a21c3186fef99888269756ae8c36ad0155b38/internal/controller/component_build_controller_secrets.go), and [error IDs](https://github.com/konflux-ci/build-service/blob/ab6a21c3186fef99888269756ae8c36ad0155b38/pkg/boerrors/perror.go).

Evidence: [Build Service scenarios](../../.prototype-results/source-entry/build-service.jsonl).

## Actual build-trigger request

The harness calls `TriggerPaCBuild` against a loopback HTTP fixture.
The fixture records the actual request and returns HTTP 403.
It does not implement PaC authentication.

The request has this shape:

```json
{
  "params": {"source_url": "https://github.com/konflux-ci/application-api"},
  "secret": "",
  "repository": "local-source",
  "branch": "main",
  "pipelinerun": "local-source-main-on-push",
  "namespace": "source-entry-prototype"
}
```

The empty secret is deliberate.
The experiment does not invent a credential to make the path succeed.
HTTP 403 produces an error with the endpoint, redacted parameters, and `returned HTTP 403`.

The existing request selects a repository, branch, and named push pipeline.
It does not carry a working-tree archive, canonical source digest, or remote execution receipt.
Working-tree checks therefore need a separate admission path.

### Observed transport reporting gap

The harness closes its loopback server and calls the same trigger method again.
The connection fails, but `TriggerPaCBuild` returns nil.
This is a failed delivery, not a successful build.

Current source logs the POST error and executes `return nil` at [component_build_controller_pac.go](https://github.com/konflux-ci/build-service/blob/ab6a21c3186fef99888269756ae8c36ad0155b38/internal/controller/component_build_controller_pac.go#L354-L357).
The relevant block starts at line 354 in the inspected revision.
An upstream fix should return the transport error and preserve retry visibility.
The prototype asserts the current behavior so the evidence remains explicit.

## Actual PaC resolver and incoming parser

The unmodified PaC CLI resolves a local PipelineRun and Task fixture.
It substitutes `revision` and `repo_url`, then embeds the Task as `taskSpec`.
The resolver uses `--no-secret`, `--remoteTask=false`, and an offline kubeconfig at `127.0.0.1:1`.
It creates no provider credentials and submits no resources.

The supplied revision is a synthetic fixture commit identifier.
This step proves template substitution, not that the remote repository contains that commit.
The resolver performs no Git checkout.

Removing the local Task yields the exact error:

```text
Error: cannot find referenced task local-check. if it's a remote task make sure to add it in the annotations
```

A second command exposes the actual private `parseIncomingPayload` function through a temporary Go build overlay.
The overlay adds an export wrapper and replaces a command entry point.
It does not copy or change the parser implementation.
The upstream worktree remains clean.

The parser rejects Build Service's captured empty-secret payload with:

```text
missing required fields: [secret]
```

It rejects malformed JSON with:

```text
invalid JSON body for incoming webhook: unexpected end of JSON input
```

This command exercises parsing only.
It does not run an HTTP listener, compare a stored incoming secret, resolve a provider installation, or authorize a build.

Source hooks: [CLI resolver](https://github.com/openshift-pipelines/pipelines-as-code/blob/81817032ba22f09db838d264fa16acc0775dc2b5/pkg/cmd/tknpac/resolve/resolve.go) and [incoming parser](https://github.com/openshift-pipelines/pipelines-as-code/blob/81817032ba22f09db838d264fa16acc0775dc2b5/pkg/adapter/incoming.go).

Evidence: [resolved pipeline](../../.prototype-results/source-entry/resolved.yaml), [resolver failure](../../.prototype-results/source-entry/pac-missing-task.log), and [incoming parser results](../../.prototype-results/source-entry/pac-incoming-parser.jsonl).

## Resolved configuration through actual Tekton

The cluster stage submits the resolved fixture in `source-entry-prototype`.
It adds a unique generated name and an explicit service account selection.
It disables service account token automount and checks the resulting Pod specification.

The observed PipelineRun `source-entry-sjr5v` completed successfully.
Its task printed `local source-entry fixture`.
The Pod used the selected service account without a projected service account token.

This establishes local PaC resolution, Tekton admission, scheduling, and execution for the pinned fixture.
Manual submission bypasses PaC event handling and provider authorization.
It does not establish that a GitHub push would create this PipelineRun.

Evidence: [cluster summary](../../.prototype-results/source-entry/cluster.json), [PipelineRun](../../.prototype-results/source-entry/pipeline.json), and [Pod specification](../../.prototype-results/source-entry/pods.json).

## Deliberate GitHub boundary

The user selected local prototypes and documentation of the GitHub boundary.
The experiment stops before these provider operations:

- GitHub App installation and installation token issuance.
- Authenticated webhook reception and event processing.
- Provider access to repository files and commits.
- Creation or updates of `.tekton` configuration pull requests.
- Provider status updates and pull request comments.
- An end-to-end GitHub push or pull request build.

GitHub App configuration is one supported authorization path.
Build Service also supports repository SCM credentials and provider webhooks.
The experiment configures neither path.
Missing authorization remains an observed prerequisite failure.

## Extension decisions

- Keep normal Git onboarding and release promotion on the existing Component path.
- Add an independent immutable source submission path for working-tree checks.
- Reuse PaC resolution only when the extension explicitly supports its template and task semantics.
- Inspect Component status messages when onboarding returns no active build.
- Separate local resolution success, webhook acceptance, PipelineRun creation, and completed execution in status reporting.
- Track the trigger transport reporting gap as an upstream contribution candidate.
- Treat GitHub event and authorization behavior as unverified until a separately authorized provider experiment runs.

## Resources and cleanup

Only the Tekton stage creates live resources.
Those resources reside in `source-entry-prototype`.
The experiment does not install Build Service or change operator, signing, release, or lifecycle configurations.

Remove the namespace with the dedicated kubeconfig and context when inspection finishes.
Local evidence remains under `.prototype-results/source-entry`.
Local binaries and overlay files remain under `.prototype-state/source-entry`.
