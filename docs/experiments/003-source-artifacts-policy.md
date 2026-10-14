# Source identity, OCI artifacts, and execution evidence

Date: 2026-10-14.

## Questions

Can a caller submit an exact working tree through existing Konflux artifact transport?
Which evidence does current Conforma policy require?
Which additional evidence must a remote sandbox return?

## Execution

Run from the prototype worktree:

```sh
make -C prototypes/artifacts run
```

All four scenarios completed.
The [prototype source](../../prototypes/artifacts/README.md) contains each executable command.
The commands preserve their output under `.prototype-results/artifacts`.

The experiment used these versions:

| Component | Version |
|---|---|
| Go compiler | `go1.27.2 linux/amd64` |
| Prototype Go target | `1.26.0` |
| ORAS | `1.3.4+Homebrew` |
| Conforma CLI | `v0.9.64`, from the policy repository's `go.mod` |
| Embedded OPA | `1.15.2` |
| Trusted Artifact scripts | `dbbc7016f5867e204ced75a64a8ce3668723067d` |
| Conforma policy | `13bc0cd118e1f53be6bd48222e24b99d36a0f30e` |
| Registry image | `registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373` |

The registry uses the Docker `kind` network.
Its current endpoint is `172.18.0.5:5000`.
It has no published host port, authentication, or TLS.
The experiment uses only synthetic data.
These settings are unsuitable for production evidence or credentials.

## Exact working-tree identity

The fixture contains staged changes, unstaged changes, a tracked deletion, executable mode changes, and selected untracked files.
It also contains a selected relative symlink and an excluded synthetic private file.

The exporter reads tracked paths and explicitly selected untracked paths.
It sorts entries and records path, type, normalized executable mode, content digest, and symlink target.
The manifest also records the base commit and deleted paths.
It excludes timestamps and Git index state.

| Scenario | Observed result |
|---|---|
| Change file timestamps | Source identity remains the same |
| Stage existing content | Source identity remains the same |
| Change selected file bytes | Source identity changes |
| Change executable mode | Source identity changes |
| Change selected symlink target | Source identity changes |
| Change excluded file bytes | Source identity remains the same |
| Select an additional untracked file | Source identity changes |
| Restore selected archive | Bytes, modes, and symlink targets match |
| Change or remove content after restoration | Manifest validation rejects the source |
| Delete a tracked file | Manifest records its path |

The canonical archive digest remained `sha256:7bfa41f22d7d95940022772f3c5e8264957e9458d1932c166f5d891d87cfa2d8` across repeated executions.
The manifest includes the base commit, so a different base commit changes source identity.

The importer uses a fresh destination and Go `os.Root` operations.
It validates all headers before it writes files.
It rejects traversal, absolute paths, escaping symlinks, symlink parents, duplicate entries, hard links, device files, and oversized files.
It limits the archive to 1,000 entries and 16 MiB of declared file content.
Each negative scenario produced a rejection.

Evidence: [source results](../../.prototype-results/artifacts/source.json).

The `import-verify` CLI binds import to an expected manifest digest before extraction.
Its standalone scenario accepts the matching digest and rejects a wrong digest without creating the destination.
The runtime prototype uses this same helper for the composed OCI-to-Kata check.

This exporter does not define production handling for submodules, Git LFS, sparse checkouts, ignored files, or filesystem races during capture.
A production exporter must capture immutable file bytes before it publishes the manifest.
The prototype's memory archive contains captured bytes, but its Git inventory can still change during capture.

## Actual Trusted Artifact transport

The experiment executes the unchanged upstream `create-oci.sh` and `use-oci.sh` scripts.
It supplies ORAS `--plain-http` and a local empty authentication file.
It replaces only the unavailable `retry` executable with a single-attempt adapter.
It does not assess retries.

The helper pushed a real OCI manifest and archive layer into the registry.
The restore helper fetched the layer by digest and restored matching source archive and manifest bytes.
A separate ORAS download passed `sha256sum -c`.

Three integration details matter:

1. The helper's `oci:repository@sha256:...` value identifies an archive blob.
   The OCI manifest has a separate digest.
   Chains signs the manifest subject, so the extension must preserve their relationship.
2. `gzip -n` removes gzip timestamp variation.
   The helper still includes tar metadata.
   Changing one source file timestamp changed the helper's archive digest.
3. The restore helper retains unrelated files in an existing destination.
   A synthetic stale file remained after extraction.
   Exact source restoration therefore requires a fresh destination.

The archive safety negatives exercise the prototype importer.
They do not establish safety properties for the upstream shell extraction path.
Untrusted uploads need validation before extraction into an execution environment.

Evidence: [transport results](../../.prototype-results/artifacts/transport.json), [create log](../../.prototype-results/artifacts/create.log), and [restore log](../../.prototype-results/artifacts/restore.log).

## Actual Conforma producer policy

The policy scenario uses the Conforma CLI's embedded OPA.
It loads the actual cloned policy modules and the upstream Trusted Artifact fixture.
The scenario stubs OCI manifest lookups with the upstream fixture functions.
It does not stub producer graph evaluation or task trust rules.

| Input | Observed result |
|---|---|
| Original trusted producer graph | No denials |
| Additional input without a producer | `trusted_task.valid_trusted_artifact_inputs` denial |
| Untrusted task in the producer chain | `trusted_task.trusted` denial |
| Matching output claim from a trusted task | No denials |

The last result follows the policy's trust model.
Policy evaluates the attested task records.
It does not independently observe remote execution.
This scenario does not verify signatures or prove that a task actually produced its claimed output.

The sibling Konflux lifecycle prototype separately verified real Chains signatures and SLSA provenance for a synthetic OCI manifest.
Its Conforma validation used `--policy '{"sources":[]}'` and the Chains public key.
That establishes cryptographic provenance validation without release policy coverage.
The two experiments establish different properties and must retain that distinction.

Evidence: [policy summary](../../.prototype-results/artifacts/policy.json), [missing producer](../../.prototype-results/artifacts/policy-missing-producer.json), and [untrusted producer](../../.prototype-results/artifacts/policy-untrusted-producer.json).

## Proposed remote execution receipt

The receipt scenario implements proposed extension rules in Go.
It creates ephemeral Ed25519 keys in memory and signs real payloads.
It stores no private keys.

The verifier requires an authorized supervisor issuer and a valid signature.
It binds the receipt to request UID, attempt, source, check definition, environment, and requested profile.
It checks issue time, expiry time, and execution deadline.
It also requires observed runtime, observed profile, network policy, credential policy, and supervisor identity.

| Scenario | Observed result |
|---|---|
| Valid signed scoped receipt | Accept evidence |
| Wrong source, check, environment, profile, or request | Reject |
| Previous attempt | Reject |
| Expired receipt, old issue time, or excessive expiry | Reject |
| Missing or mismatched observed enforcement | Reject |
| Untrusted guest issuer | Reject |
| Signed dispatcher receipt | Reject |
| Dispatcher claims supervisor enforcement | Reject |
| Dispatcher changes its issuer to supervisor | Reject signature |
| Changed signed payload | Reject signature |
| Timeout result | Reject as inconclusive |
| Valid receipt for a failed check | Accept evidence; deny promotion |

A signature authenticates a supervisor's claim.
It does not independently measure a VM or prove the supervisor's implementation.
Production enforcement still needs a trusted supervisor, enforced profiles, and runtime conformance checks.
These rules are a proposed extension contract, not existing Conforma behavior.

Evidence: [receipt results](../../.prototype-results/artifacts/receipts.json).

## Upstream integration points

The existing [OCI creator](https://github.com/konflux-ci/build-trusted-artifacts/blob/dbbc7016f5867e204ced75a64a8ce3668723067d/create-oci.sh) and [OCI restorer](https://github.com/konflux-ci/build-trusted-artifacts/blob/dbbc7016f5867e204ced75a64a8ce3668723067d/use-oci.sh) can carry a validated source package.
The extension needs a source importer that validates content and records the blob-to-manifest relationship.

The [Trusted Artifact policy](https://github.com/conforma/policy/blob/13bc0cd118e1f53be6bd48222e24b99d36a0f30e/policy/release/trusted_task/trusted_task.rego) evaluates input producers and their task trust.
An external upload cannot obtain normal producer trust from its digest alone.
A trusted import task needs an explicit authority and a recorded output.

The [Chains signer](https://github.com/tektoncd/chains/blob/0b20951e9e55cc1f0631c51ee20359f5568eb9e2/pkg/chains/signing.go) signs Tekton execution records.
A dispatcher task's signature does not make its external workload a directly observed Tekton execution.
The extension needs separate supervisor evidence and policy for that workload.

## Architecture decisions

- Preserve source identity separately from transport blob and OCI manifest identity.
- Import source into a fresh destination through a bounded importer.
- Keep uploaded source advisory until an explicit trusted producer imports and records it.
- Record both manifest subject and archive layer when existing OCI helpers carry source.
- Require supervisor evidence for remote execution.
- Evaluate dispatcher provenance and remote execution evidence separately.
- Keep valid failed execution evidence separate from permission to promote an artifact.
- Keep private source, findings, and execution evidence out of public transparency services by default.

## Remaining work

The prototype does not validate a real VM, tenant isolation, authenticated registry storage, or retention policy.
It does not implement a source import controller, production signer, or release policy for remote receipts.
It does not exercise all Conforma release collections.
Those requirements remain separate implementation and verification work.
