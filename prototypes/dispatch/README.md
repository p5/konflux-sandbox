# Remote dispatch prototype

Question: can a Tekton task and local client use the same asynchronous execution interface?

Run `make prototype-dispatch` from the repository root.
The command requires the explicit prototype kubeconfig and its disposable Kind cluster.
It builds a local image and loads that image into the selected cluster.
It does not publish an image externally.

The endpoint runs actual bounded shell commands inside its container.
It verifies source digests and rejects conflicting request identities.
The scenarios cover passing commands, failing commands, cancellation, and deadlines.
The Tekton workflow consumes an execution result through its ordinary task result interface.
An actively running PipelineRun also forwards cancellation to the endpoint in the tested signal path.
The background-child scenario checks process-group cleanup after a passing parent exits.

This endpoint uses synthetic authentication and an in-memory request map.
The command shares the endpoint's container and kernel.
It demonstrates dispatch semantics without establishing a production security boundary or durable recovery.
The runtime prototype supplies separate VM evidence.
Production cancellation needs an external workflow owner because a Pod crash can bypass its exit handler.
