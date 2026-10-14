# Private evidence fixture

This fixture checks private logs, artifacts, signed receipts, and retention behind an mTLS interface.
It uses the shared prototype identity issuer.
It does not implement a product workflow or a production storage backend.

Run the scenarios:

```sh
make -C prototypes/private-evidence run
```

The command builds a standalone binary under `.prototype-state/private-evidence`.
It writes its summary under `.prototype-results/private-evidence`.
The standalone scenario removes its temporary certificate and key directory on exit.

## API

All routes start with:

```text
/v1/owners/{owner}/requests/{request}/attempts/{attempt}
```

The verified certificate URI binds owner, request, attempt, and guest UID.
The service rejects scope mismatches before it reads stored data.

| Method and suffix | Required role | Behavior |
|---|---|---|
| `POST` base route | `control` | Open an evidence grant with an absolute expiry |
| `GET /metadata` | `control` | Read identities, expiry, state, and checksums |
| `POST /logs` | `control` or `execution` | Append bounded private log bytes |
| `GET /logs` | `control` | Read the current archived bytes |
| `GET /logs?follow=true` | `control` | Stream chunks until sealing or expiry |
| `PUT /artifacts/{name}` | `control` or `execution` | Store one immutable artifact |
| `GET /artifacts/{name}` | `control` | Retrieve private artifact bytes |
| `PUT /receipt` | `control` | Verify the supervisor signature and seal matching content |
| `GET /receipt` | `control` | Retrieve the signed receipt |

A grant uses `Grant` in [receipt.go](receipt.go).
Its `expires_at` value is an absolute timestamp.
The service cannot extend an existing grant or revive an expired request.

A receipt uses `Receipt` inside an `Envelope`.
The envelope contains an issuer, base64 payload bytes, and a base64 Ed25519 signature.
The service holds only the supervisor public key.
It does not mint an authoritative receipt.

The signature binds scope, source, tool, profile, backend, timestamps, result, log digest, and artifact digests.
The service requires observed Pod identity.
Kata and Agent Sandbox receipts also require distinct guest and node kernels, the selected RuntimeClass, and the profile digest.
Those fields remain authenticated supervisor observations.
The storage service does not independently inspect a VM or firewall.

Receipt acceptance seals the log and artifact set.
Subsequent writes return HTTP 409.
Follow streams return `X-Evidence-Stream-State` as an HTTP trailer.
Clients must distinguish `sealed` from `expired` or an interrupted connection.

## Standalone server

Build the binary with `make -C prototypes/private-evidence build`.
The shared issuer must provide the server certificate and owner certificates.
The trusted observer must generate the supervisor signing key outside guests.

```sh
.prototype-state/private-evidence/evidence -serve \
  -ca PRIVATE_STATE/ca.crt \
  -cert PRIVATE_STATE/server.crt \
  -key PRIVATE_STATE/server.key \
  -server-name SERVER_DNS_NAME \
  -supervisor-key PRIVATE_STATE/supervisor-public.base64 \
  -issuer supervisor \
  -listen 127.0.0.1:0 \
  -ready-file PRIVATE_STATE/evidence-ready.json \
  -max-retention 5m
```

Keep private state under an ignored directory.
The public key file contains the standard base64 encoding of 32 Ed25519 public-key bytes.
The ready file contains the local HTTPS address and expected server DNS name.

The nested module exports `NewStore`, `Grant`, `Metadata`, `Receipt`, `Envelope`, `Digest`, `Sign`, and `Verify`.
The root foundation composition can use these types without duplicating the wire format.

## Limits

The store keeps bytes in host memory.
It survives producer removal while its server remains alive.
It does not establish crash recovery or production object storage durability.
Expiry removes logical payloads and denies retrieval.
It retains a small request tombstone to prevent revival.
It cannot erase copies that clients already downloaded.

The standalone command uses a real local producer subprocess.
It does not claim actual guest or namespace deletion.
The foundation composition must exercise those operations with the same API.

See [the experiment report](../../docs/experiments/014-private-evidence.md).
