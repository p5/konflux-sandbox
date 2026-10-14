# Private logs, artifacts, receipts, and retention

Date: 2026-10-14.

## Question

Can one private evidence interface enforce owner scope and preserve output independently of a producer's lifetime?
Can it reject guest authority and enforce a fixed deletion deadline?

## Execution

```sh
make -C prototypes/private-evidence run
```

The [fixture](../../prototypes/private-evidence/README.md) uses real TLS 1.3 connections and x509 client certificates.
It uses the shared `identity/pki` issuer and its scoped URI convention.
The issuer and supervisor keys remain outside the producer process.
The producer receives only its scoped execution certificate, leaf key, and public CA certificate.

The standalone producer is an actual local subprocess.
It appends private log chunks and uploads an artifact through HTTPS.
The parent observes the first streamed chunk before the producer exits.
The parent then waits for producer exit before it retrieves the archived logs and artifact.

The evidence server holds bytes in memory.
The fixture does not establish VM isolation, namespace deletion, or persistence across server failure.
Actual guest and namespace removal belongs to the root foundation composition.

Evidence: [scenario summary](../../.prototype-results/private-evidence/summary.json).

## Identity and access

The certificate URI has this form:

```text
spiffe://konflux-sandbox.prototype/owner/{owner}/request/{request}/attempt/{attempt}/guest/{guestUID}
```

The certificate organizational unit identifies its role.
The service requires a verified certificate chain before it parses the identity.
It checks owner, request, attempt, and guest UID against the selected record.
It accepts no identity header as authority.

| Scenario | Observed result |
|---|---|
| No client certificate | TLS rejects the client |
| Owner A opens and retrieves its record | Permit |
| Owner B opens and retrieves its record | Permit |
| Owner B reads Owner A's logs, artifacts, metadata, or receipt | HTTP 403 |
| Owner A reads Owner B's logs | HTTP 403 |
| Owner B appends to Owner A's logs | HTTP 403 |
| An execution identity reads archived logs | HTTP 403 |
| A certificate for attempt 1 requests attempt 2 | HTTP 403 |

Control identities open grants, retrieve evidence, and submit receipts.
Execution identities can only append logs and create artifacts in their issued scope.

## Private output and producer removal

The owner opens a grant with a fixed absolute expiry.
The grant binds guest UID, source digest, tool digest, profile digest, and backend.
An identical repeated open operation is idempotent.
A conflicting open cannot replace the grant.

The producer sends two private log chunks through separate authenticated requests.
The owner's follow stream delivers the first chunk before producer exit.
After producer exit, ordinary reads return both chunks and the uploaded artifact.
Owner B cannot retrieve those bytes.

Artifacts are immutable after their first successful write.
The service limits each artifact to 1 MiB and each record to four artifacts.
It limits accumulated log bytes to 64 KiB.

This proves private output retrieval independently of the local producer process.
It does not prove recovery after the evidence server stops.

## Independent supervisor receipt

The evidence server holds an Ed25519 public key.
The trusted local observer holds the corresponding private key outside the producer.
The observer signs an envelope after it observes the producer's certificate identity, process exit, and stored content digests.

The receipt binds:

- Owner, request, attempt, and guest UID.
- Source, tool, profile, and backend identities.
- Issue time, completion time, outcome, and retention deadline.
- The complete stored log digest and artifact digest map.
- Explicit supervisor observations.

The standalone receipt declares `local-producer-fixture` as its backend.
Its observations identify the actual producer process and issued client URI.
It makes no claim about VM or firewall enforcement.

| Receipt scenario | Observed result |
|---|---|
| An untrusted guest signer submits a receipt | HTTP 422 |
| A trusted signer supplies the wrong source digest | HTTP 422 |
| A trusted signer supplies the wrong content digest | HTTP 422 |
| The signed payload changes | HTTP 422 |
| An execution identity submits an otherwise valid receipt | HTTP 403 |
| The control identity submits the matching supervisor receipt | HTTP 201 |
| The owner retrieves and verifies that receipt after producer exit | Permit |
| A caller appends logs after receipt acceptance | HTTP 409 |

Receipt acceptance seals the stored bytes.
The follow stream ends with the `sealed` trailer value.
An expiry or transport interruption must not count as successful stream completion.

The same format supports actual Kata TaskRun and Agent Sandbox observations.
For those backends, the verifier requires a matching Pod UID, RuntimeClass, profile digest, and distinct guest and node kernels.
The root trusted observer must obtain those values from actual execution before it signs.
The storage service authenticates that observer's statement; it does not measure runtime enforcement itself.

The server never receives a supervisor private signing key.
The guest cannot obtain receipt authority from an execution certificate.

## Retention and retrieval revocation

Both owners' grants expire after four seconds in the standalone scenario.
The service's janitor removes log, artifact, and receipt payloads at the absolute deadline.
Reads also check expiry before they return content.

After expiry:

- Metadata, logs, artifact, and receipt reads return HTTP 410.
- An attempted log append returns HTTP 410.
- An attempted grant renewal for the same request and attempt returns HTTP 410.
- The store reports zero retained payload bytes.

The service retains a small scope tombstone to prevent revival.
This is logical deletion inside the fixture.
It does not prove forensic erasure or deletion of copies that clients downloaded earlier.

Certificate expiry, evidence retention, and guest removal are separate lifecycles.
An archive can remain readable by its authorized controller after the guest disappears.
An expired evidence record remains unreadable even while its owner certificate still works.

## Foundation integration

The host server exposes the same interface for finite and interactive execution.
Its routes scope data by owner, request, and attempt.
The certificate adds the guest UID check.

The root composition can upload actual output through a trusted outside observer.
It can then remove the guest and its namespace before it reads the archive again.
The observer signs the actual identity, runtime, policy, and content observations.
The evidence service validates that signature and the stored checksums before it seals the record.

This interface is an object-storage adapter contract.
It is separate from Results' archived PipelineRun and TaskRun records.
It also works when the producer is an Agent Sandbox session without a PipelineRun.
The earlier [Results experiment](009-results-diagnostics.md) established run-record archival and found that Results logs were disabled.
This fixture supplies an explicit private log and artifact path without changing Results configuration.

## Remaining work

The fixture does not implement production object storage, backup, crash recovery, key rotation, or issuer revocation.
The shared identity and gateway prototypes own immediate execution credential revocation.
The storage service accepts writes until sealing, retention expiry, or certificate expiry.
Its memory store must become a private durable backend before production use.

No cluster resources, model requests, Git provider actions, or external publication occur in this standalone command.
Generated credentials and evidence remain under ignored prototype directories.
The standalone scenario removes its temporary certificate directory on exit.
