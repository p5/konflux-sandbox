# Source, artifact, and receipt prototype

This throwaway prototype checks source identity, OCI transport, producer policy, and remote execution receipt rules.

Run all scenarios from this directory:

```sh
make run
```

The prototype uses the sibling `build-trusted-artifacts` and `conforma-policy` clones.
It requires Go, Git, Docker, ORAS, jq, curl, and the existing Docker `kind` network.
The first policy command builds the Conforma CLI version from the policy repository's `go.mod`.

The prototype creates only synthetic source and credentials.
It stores temporary files under `.prototype-state/artifacts` and results under `.prototype-results/artifacts`.
It creates a registry on the Docker `kind` network without a published host port.

Individual commands:

```sh
make source
make transport
make policy
make receipts
make import-verify
```

The static helper also supports composition with a real execution environment:

```sh
source-helper import-verify SOURCE_TAR MANIFEST_JSON FRESH_DEST EXPECTED_MANIFEST_DIGEST
```

The helper checks the manifest digest before extraction.
It then validates archive paths and restored file content.

The OCI commands run the upstream scripts without changes.
A single-attempt adapter replaces their unavailable `retry` binary.
The prototype does not assess retry behavior.

The receipt verifier implements proposed extension rules.
It does not implement existing Conforma policy or measure runtime enforcement.

Other prototypes share the registry.
After those prototypes finish, remove this disposable registry:

```sh
make cleanup
```

See [the experiment report](../../docs/experiments/003-source-artifacts-policy.md).
