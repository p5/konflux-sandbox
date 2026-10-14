# Execution identity and encrypted transport

Run `make run` after the runtime prototype installs the Kata cluster and its execution image.
The suite creates one Kata guest at a time in `foundation-identity-prototype`.
It removes guests, opaque TCP relays, services, and local servers when the suite ends.
Private keys and captures stay in ignored `.state/` and `evidence/` directories.

## Shared fixture interface

The nested Go module exports package `github.com/p5/konflux-sandbox/prototypes/identity/pki`.

```go
type Identity struct {
    Owner string
    Request string
    Attempt string
    GuestUID string
}

func Issue(state string, identity Identity, role string, ttl time.Duration) (Files, error)
func Parse(certificate *x509.Certificate, requiredRole string) (Identity, error)
func TLS(caFile, certificateFile, keyFile string) (*tls.Config, error)
```

`Parse` checks the URI, role, and current certificate validity.
The caller must first verify the certificate chain through TLS or another trusted verifier.
`Issue` is a trusted local fixture utility. It does not authorize callers or attest a guest.

The identity URI is:

```text
spiffe://konflux-sandbox.prototype/owner/OWNER/request/REQUEST/attempt/ATTEMPT/guest/POD_UID
```

The certificate's organizational unit selects `control`, `execution`, `server`, `gateway`, or `broker` role.
Identity segments accept lowercase letters, digits, and hyphens.
The suite uses actual Pod UIDs from Kubernetes.

The binary also supplies these fixture commands:

```text
identity issue STATE OWNER REQUEST ATTEMPT POD_UID ROLE SECONDS
identity guest TLS_DIRECTORY
identity gateway STATE_DIRECTORY LISTEN_ADDRESS
identity broker STATE_DIRECTORY LISTEN_ADDRESS
identity client TLS_DIRECTORY SERVER_NAME URL GRANT EXPECTED_STATUS OUTPUT_FILE
```

`issue` returns JSON paths for the public CA, leaf certificate, leaf private key, and expected server name.
The CA private key remains in `STATE/ca.key`.
Do not distribute that file to a guest or fixture producer.

Each TLS directory contains `ca.crt`, `tls.crt`, and `tls.key`.
The guest TLS directory also contains `identity.json` with the exact execution identity.
The guest command listens on TLS port 8443 and forwards REST and streaming gRPC to loopback sandboxd.

The gateway loads `routes.json` with `active` and `routes` maps.
`active` maps `OWNER/REQUEST/ATTEMPT` to the current guest UID.
Each route has `identity`, `url`, `serverName`, and `tlsDir` fields.
The gateway requires a control certificate and an `X-Guest-UID` request header.
It verifies the route's server certificate and execution identity before forwarding.

The broker loads `grants.json` with `active` and `grants` maps.
Each grant has `identity`, `expires`, `revoked`, and `action` fields.
This fixture permits action `read-fixture` through `GET /operation` and requires header `X-Grant`.
It supplies its own fixed local upstream server and generates that server's credential outside the guest.

Both servers write their selected listen address to `STATE_DIRECTORY/address`.
Host-side configuration updates use atomic file replacement.
Revocation checks run every 20 milliseconds during active requests.

See [experiment 012](../../docs/experiments/012-identity-transport.md) for results and limits.
