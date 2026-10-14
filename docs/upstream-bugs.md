# Upstream bug candidates

Observed: 14 October 2026.
These findings apply to the pinned revisions below.
Check current upstream code before preparing each fix.
Each bug can have a separate upstream pull request.

## Integration Service truncates image references with registry ports

Repository: [konflux-ci/integration-service](https://github.com/konflux-ci/integration-service).
Revision: `a5e72c8f7f38fef128feccdda1de53d99a6823f4`.
Function: `GetImagePullSpecFromPipelineRun`.
Source: [tekton/build_pipeline.go:195](https://github.com/konflux-ci/integration-service/blob/a5e72c8f7f38fef128feccdda1de53d99a6823f4/tekton/build_pipeline.go#L195-L204).

### Observed behavior

The function uses `strings.Split(outputImage, ":")[0]` before it appends the image digest.
For a registry with an explicit port, this operation removes the port and repository path.
The live controller created a Snapshot with the incorrect reference.
Conforma then rejected that Snapshot's image reference.

```text
IMAGE_URL:             172.18.0.5:5000/prototype/source
IMAGE_DIGEST:          sha256:<digest>
Observed Snapshot:    172.18.0.5@sha256:<digest>
Expected Snapshot:    172.18.0.5:5000/prototype/source@sha256:<digest>
```

### Local reproduction

Run from the prototype repository root with the retained cluster and registry available:

```sh
make -C prototypes/konflux registry-port-bug
```

The target checks the actual controller-created Snapshot and the subsequent Conforma rejection.
It currently asserts the buggy behavior; update those assertions after a fix.
The other lifecycle scenarios use a portless proxy as a workaround.

Evidence: [lifecycle report](experiments/002-konflux-lifecycle.md#registry-port-failure).
Local captures: `.prototype-results/konflux/port-bug-*`.

### Suggested fix and regression cases

Use an OCI reference parser to preserve the registry authority and repository when replacing a tag with the result digest.
Cover registries with and without explicit ports, with both tagged and untagged image references.
Confirm that the Snapshot preserves the complete repository reference and uses the IMAGE_DIGEST result.
Confirm that downstream verification can retrieve the intended artifact.

## Build Service returns nil after an incoming request transport failure

Repository: [konflux-ci/build-service](https://github.com/konflux-ci/build-service).
Revision: `ab6a21c3186fef99888269756ae8c36ad0155b38`.
Function: `TriggerPaCBuild`.
Source: [internal/controller/component_build_controller_pac.go:354](https://github.com/konflux-ci/build-service/blob/ab6a21c3186fef99888269756ae8c36ad0155b38/internal/controller/component_build_controller_pac.go#L354-L357).

### Observed behavior

The function sends an HTTP POST to the Pipelines-as-Code incoming endpoint.
If the HTTP client returns a transport error, the function logs that error and returns nil.
The caller therefore receives no error for a failed delivery.
This observation does not establish successful webhook acceptance or build creation.

The local prototype closes its loopback HTTP server before calling the actual upstream function.
The connection fails, but the function returns nil.
A separate HTTP 403 fixture returns an error correctly.

### Local reproduction

Run from the prototype repository root:

```sh
make -C prototypes/source-entry build-service
```

This target uses actual upstream functions with an in-memory Kubernetes client and a loopback HTTP fixture.
It requires no cluster, GitHub App, provider credentials, or GitHub API actions.
Inspect the `actual-trigger-connection-refused` record for `deliverySucceeded:false` and `methodError:null`.
The prototype currently asserts the buggy behavior; update that assertion after a fix.

Evidence: [source-entry report](experiments/008-source-entry.md#observed-transport-reporting-gap).
Local capture: `.prototype-results/source-entry/build-service.jsonl`.

### Suggested fix and regression cases

Return the transport error, with context if needed, and preserve the underlying error for callers.
Keep incoming secrets redacted in logs and error messages.
Cover connection refusal, request timeout, and request cancellation.
Preserve the existing error behavior for unsuccessful HTTP responses and success behavior for HTTP 202.
Check how the caller records or retries a failed trigger after error propagation changes.
