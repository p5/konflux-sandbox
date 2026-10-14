# Credential broker grant experiment

Date: 14 October 2026.

Question: can the broker enforce one permitted upstream operation without exposing its upstream credential to the caller?

Run `make prototype-broker`.
The program starts local HTTP servers with synthetic identities and a synthetic upstream secret.
It uses no external model, repository, or credential.

## Observations

| Scenario | Observed result |
| --- | --- |
| Another execution uses the grant | HTTP 403 |
| Guest supplies another destination | HTTP 403 |
| Guest changes the permitted HTTP method | HTTP 405 |
| Authorized operation | HTTP 200; upstream accepts injected credential |
| Grant budget exhausted | HTTP 429 |
| Upstream redirects to another server | HTTP 502; redirect target receives no request |
| Grant expired | HTTP 410 |
| Grant revoked | HTTP 410 |
| Request exceeds body limit | HTTP 413 |
| Revocation during an upstream request | In-flight request cancels; HTTP 410 |
| Two concurrent requests share one remaining operation | One HTTP 200 and one HTTP 429 |

Every response check confirmed that the upstream secret was absent from the response body.
Only the two accepted budgeted operations reached the inference handler.
The redirect target received no request.

The HTTP fixture consumes the request body before it waits for cancellation.
This lets the server observe client disconnection during the long-running request.
Production streaming and backpressure need their own cancellation contract.

## Decisions

The grant binds an authenticated execution identity to a fixed operation and destination.
The caller cannot select an upstream credential or redirect its use.
Budget consumption requires an atomic update.
Revocation must cancel active upstream work as well as reject new work.

The prototype checks operation counts.
Model token accounting, cost reconciliation, provider retries, and streaming response accounting need later implementation.

## Limits

The prototype's identity map represents an already authenticated caller.
It does not verify Kubernetes OIDC tokens, token audiences, TLS identities, or execution UID attestations.
It does not establish network isolation.

The separate runtime experiment demonstrated a tested NetworkPolicy restriction for ordinary and Kata clients.
The broker and runtime controls still need a composed production implementation.
An allowed model destination can receive source data, so grant authorization must also cover disclosure.

Evidence remains under `.prototype-results/broker.log` or the aggregate `.prototype-results/local.log`.
