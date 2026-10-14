# Results archival, authorization, and failure diagnostics

Date: 2026-10-14.

## Questions

Can the extension retrieve workflow evidence after Kubernetes deletes the live run?
Does Results enforce namespace access?
Can existing diagnostic code consume archived run data?
Does this installation archive logs?

## Execution

```sh
make -C prototypes/results run
```

The [prototype](../../prototypes/results/README.md) completed its record, authorization, diagnostic, and deletion scenarios.
It used the existing Results installation without global configuration changes.

| Component | Observed version or source |
|---|---|
| Installed Results API | `v0.20.0@sha256:b0d55e887a79d195d9964f42c3a1dc7967fb08f5307c350ab51905f9897a34ff` |
| Installed Results watcher | `v0.20.0@sha256:a5fb2d24d5c455c62fda7ce80c36b39af1e50d482a4bfdd289f436287f3c21c9` |
| Inspected Results release source | `e175d25e526e9ac7221e50011d2ef3b845502002`, tag `v0.20.0` |
| Results clone main revision | `c893decf6a09571547ce4837224e808e041025cf` |
| Diagnostic script source | `240c80419829ad7eb82dfc4c4f6508cee9fea546` |

The clone remains on its main revision.
Source references below use the installed release's commit.

## Synthetic failed workflow

The fixture has two tasks.
The prepare task emits a source digest and succeeds.
The check task writes a structured failure result, prints a diagnostic marker, and exits with code 23.
Neither task receives a mounted Kubernetes service account token.

The observed PipelineRun was `results-diagnostics-st8qf` in `results-prototype`.
Its `Succeeded` condition was `False`, with reason `Failed`.
The failed TaskRun's reason was `StepFailed`.
Its check step recorded exit code 23 and the structured `check-result` value.

The watcher attached `results.tekton.dev/result`, `results.tekton.dev/record`, and `results.tekton.dev/stored` annotations.
The prototype waited for `stored=true`, then fetched the actual REST records.

## Actual API access and namespace isolation

The prototype forwards the existing Results Service to a temporary loopback port.
It validates TLS with the public Results certificate and the service's DNS name.
It does not disable certificate validation.

The reader service account has only `get` and `list` permissions for Results, Records, and Logs in `results-prototype`.
The local trusted client requests a ten-minute Kubernetes TokenRequest credential.
It places the credential in a private, ignored curl header file.
It removes that file on exit.
It does not print the credential or pass it into guest tasks.

| Request | HTTP status | Response |
|---|---|---|
| Own namespace without a token | 401 | Authentication denied |
| Own namespace with the scoped reader | 200 | Result and Record data |
| Lifecycle namespace with the same reader | 401 | `{"code":16,"message":"permission denied"}` |

Results authenticates tokens with Kubernetes TokenReview and authorizes namespace access with SubjectAccessReview.
Its inspected implementation returns `Unauthenticated` after failed authentication or authorization.
The HTTP 401 response therefore does not identify which check failed.
The control request proves that this reader token works in its own namespace.
Existing Results authorization is namespace scoped.
The extension must enforce any additional request-owner restrictions.

Source: [Results authorization](https://github.com/tektoncd/results/blob/e175d25e526e9ac7221e50011d2ef3b845502002/pkg/api/server/v1alpha2/auth/rbac.go).

Evidence: [summary](../../.prototype-results/results/summary.json), [permitted listing](../../.prototype-results/results/result-list.json), and [denied namespace request](../../.prototype-results/results/namespace-denied.json).

## Archived object fidelity

The actual REST Record contains a typed, base64-encoded Kubernetes object.
The prototype decodes the PipelineRun and both TaskRun records.
It compares these fields with their live Kubernetes objects:

- Kind, namespace, name, and UID.
- Terminal `Succeeded` condition status and reason.
- Structured task and pipeline results.
- Step names, termination reasons, and exit codes.

All comparisons matched.
The comparison excludes changing resource versions and metadata updates.
It does not require byte-for-byte equality between different resource revisions.
The archived object includes inline parameters and scripts.
The extension must keep credentials out of those fields.

The watcher stores run objects through the Results API.
It does not write directly to the database.

Sources: [watcher storage client](https://github.com/tektoncd/results/blob/e175d25e526e9ac7221e50011d2ef3b845502002/pkg/watcher/results/results.go) and [stored annotation handling](https://github.com/tektoncd/results/blob/e175d25e526e9ac7221e50011d2ef3b845502002/pkg/watcher/reconciler/dynamic/dynamic.go).

Evidence: [archived PipelineRun](../../.prototype-results/results/archived-pipeline.json) and [live PipelineRun](../../.prototype-results/results/live-pipeline.json).

## Failure diagnostics from actual archived records

The prototype adapts decoded Results objects into a Kubernetes List cache.
It runs the unchanged upstream `check-plr-errors.sh` script against that cache.
The script's normal fetch path uses KubeArchive through `oc ka`.
The prototype blocks uncached `oc` calls instead of forwarding them to an unrelated cluster context.

The actual analyzer reports:

```text
PipelineRun failed (Failed). Checking TaskRuns...
TaskRun failed: check
Reason: StepFailed
Step failed: check (exit code: 23, reason: Error)
```

Its output also includes the structured failure result from the step termination message.
This proves that existing analysis logic can consume Results-derived objects through a cache adapter.
It does not establish that the script natively queries Results or that KubeArchive is installed.

Source: [upstream diagnostic script](https://github.com/konflux-ci/agent-plugins/blob/240c80419829ad7eb82dfc4c4f6508cee9fea546/skills/investigating-failed-plrs/check-plr-errors.sh).

Evidence: [actual analyzer output](../../.prototype-results/results/upstream-diagnostics.txt).

## Persistence after live deletion

After it captures evidence, the prototype deletes its live PipelineRun.
The Kubernetes API no longer returns that PipelineRun.
The Results API still returns its record with HTTP 200 and the same Kubernetes UID.

The observed record path was:

```text
results-prototype/results/76ba0d37-0c05-4a0f-9162-ef2b8c1929bb/records/76ba0d37-0c05-4a0f-9162-ef2b8c1929bb
```

This establishes immediate archive availability after live object deletion.
It does not establish long-term retention, backup, recovery, or availability guarantees.

Evidence: [record after deletion](../../.prototype-results/results/pipeline-record-after-delete.json).

## Logs remain a separate capability

The installed API configuration includes:

```text
AUTH_DISABLE=false
LOGS_API=false
LOGS_TYPE=File
```

Both the log listing and log retrieval requests return HTTP 404:

```json
{"code":5,"message":"Not Found"}
```

The inspected API server registers log handlers only when the log API configuration enables them.
This installation therefore does not provide archived logs through the tested Results routes.
The prototype does not enable a backend or change its configuration.

It separately captures the diagnostic marker through the live Kubernetes Pod logs API.
That capture is live log evidence, not Results log archival.
The persisted run object and structured result remain available without archived stdout or stderr.

Source: [API and log handler registration](https://github.com/tektoncd/results/blob/e175d25e526e9ac7221e50011d2ef3b845502002/cmd/api/main.go).

Evidence: [capability configuration](../../.prototype-results/results/results-capabilities.txt), [log request failure](../../.prototype-results/results/log-get.json), and [live Kubernetes logs](../../.prototype-results/results/live-kubernetes-logs.txt).

## Extension decisions

- Use Results records for workflow history after Kubernetes prunes completed runs.
- Preserve Result and Record references with request UID and execution attempt identity.
- Keep source, environment, enforcement, and receipt evidence in explicit structured results or referenced private artifacts.
- Keep trusted API credentials outside guest workloads.
- Authorize archive access through the workflow's namespace and owner.
- Add a Results adapter to existing diagnostics instead of assuming an `oc ka` backend.
- Configure and verify log storage separately before the product promises archived logs.
- Define retention and disclosure rules for logs, findings, prompts, and artifacts independently.

## Remaining limits and resources

The prototype assesses one local Results deployment and a synthetic failed workflow.
It does not assess production scale, outage recovery, retention enforcement, or cross-cluster identity.
It does not verify signed remote sandbox execution receipts.

The reader service account and its narrow RBAC remain in `results-prototype` for inspection.
The live fixture PipelineRun does not remain.
The TokenRequest header file does not remain after normal exit.
Deleting the namespace does not prove deletion of Results database records.
The [prototype README](../../prototypes/results/README.md) gives the namespace cleanup command.
