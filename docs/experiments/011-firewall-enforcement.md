# Domain and IP firewall enforcement

Date: 14 October 2026.

## Question and chosen pattern

Can outside-guest enforcement protect both native Tekton tasks and Agent Sandbox sessions with domain and IP rules?

The prototype combines a dedicated HTTP/S gateway with packet filters on the guest's node-side network interface.
This pattern does not replace the cluster CNI.
The packet filters require privileged node authority, which belongs to the trusted foundation.
External consumers receive no authority to create or change those rules directly.

The implementation lives in [prototypes/firewall](../../prototypes/firewall/README.md).
It is throwaway research code.
The supported prototype profile is IPv4 TCP, inspected HTTP/1.1 domain traffic, and explicit IP or CIDR TCP grants.
The gateway uses TLS 1.3 for inspected HTTPS.
Unsupported UDP, IPv6 allow, opaque domain, and unknown policy fields fail admission validation.

## Execution

```sh
make -C prototypes/firewall run
```

The suite uses ordinary containers, an actual Kata Sandbox session, and an actual native Kata TaskRun.
All resources use the dedicated VM Kind cluster.
Fixture origins and DNS remain local.
No external provider, model, repository, or registry credentials enter these guests.

The ordinary and Kata session paths exercise the full destination and revocation matrix.
The native TaskRun path exercises shared gateway and fence enforcement, plus actual gateway deletion during execution.
The first trusted task step waits for explicit admission before starting its command probes.
That barrier demonstrates required ordering; production must enforce the same ordering for all untrusted commands.

## Destination behavior

| Case | Observed result |
| --- | --- |
| Approved HTTP and inspected HTTPS domain | Allowed |
| One-label wildcard child | Allowed |
| Wildcard apex, unrelated suffix, and deeper child | Denied |
| Approved and forbidden domains sharing one IP | Only approved name allowed |
| Explicit IP or CIDR and permitted port | Allowed through gateway |
| IP without a grant or port without permission | Denied |
| Direct origin, node API, cluster API, DNS TCP, gateway admin, and metadata connections | Denied by outside-guest fence |
| Alternate UDP DNS resolver | Reachable before fence; denied after fence |
| Approved domain redirected to forbidden domain | Denied on redirected request |
| Approved DNS name changes from origin A to origin B | Next request reaches B |
| DNS rebinding to node or gateway address | Denied after resolution |
| CONNECT hostname and TLS SNI disagree | Server rejects handshake and records denial |
| CONNECT hostname and encrypted HTTP Host disagree | Denied after TLS termination |
| Origin certificate does not cover an approved hostname | Upstream verification rejects the request |

Direct node API and fixture TCP connectivity succeed before the fence.
Those connections fail after it.
The positive baseline prevents a missing destination from masquerading as enforcement.

The SNI adversarial client verifies the CONNECT certificate against the approved hostname while deliberately sending a different SNI.
This avoids mistaking client hostname rejection for server enforcement.
The suite also requires the gateway's explicit SNI rejection audit record.

## Domain guarantees and limits

Domain rules authorize HTTP request names through gateway inspection.
The gateway checks CONNECT, SNI, and HTTP Host for inspected HTTPS and verifies the actual upstream certificate.
This prevents another HTTP hostname on a shared IP from gaining authority through the permitted name.
Wildcard rules match exactly one subordinate label.
Domain normalization accepts ASCII hostnames and rejects unsupported forms.

The gateway resolves each new upstream connection through its controlled resolver.
It does not cache resolved addresses or reuse upstream connections.
It rejects protected addresses after resolution and permits private fixture addresses only through explicit administrator configuration.
Existing admitted streams keep their original destination until completion, deadline, failure, or explicit revocation.
DNS expiry therefore does not silently authorize another destination for an existing connection.

HTTPS inspection requires the client to trust the gateway CA.
The trusted gateway can read inspected application data.
Opaque end-to-end TLS uses explicit IP and port authority in this prototype.
That mode does not claim hostname guarantees inside the tunnel.
UDP, HTTP/3, opaque domain tunnels, and certificate-pinned applications require another supported capability or rejection.

## Packet enforcement and control transport

The outside filter binds to the actual guest interface rather than a guest-supplied source address.
IPv4 INPUT and FORWARD hooks restrict guest-originated traffic to the gateway.
OUTPUT and FORWARD hooks restrict incoming traffic to gateway replies and any explicitly configured control relay.
The control exception permits only the relay's incoming guest TLS port and matching connection replies.
It does not authorize new guest-originated connections to that relay.
The consumer experiment composes that exception with authenticated encrypted command transport.

IPv6-enabled profiles fail validation.
The helper installs IPv6 rejection in both directions on the guest interface.
The suite attempts a link-local IPv6 baseline and a post-enforcement connection.
When the baseline is unavailable, the report treats that case as installed-rule evidence rather than a demonstrated connectivity transition.
It captures interface state and IPv6 rejection counters separately.
Supported IPv6 access needs its own positive and negative conformance matrix.

## Revocation and failures

The suite opens actual HTTP, inspected HTTPS, and opaque TCP streams.
Revocation closes the active connections and denies new requests.
Each tested closure completes within the suite's three-second bound.
The bound is a local assertion, not a production latency guarantee.

An unavailable gateway policy rejects requests until the trusted administrator restores readiness.
The native TaskRun also survives deletion of the gateway as a failed network request.
Its direct origin bypass remains blocked by the node fence.
The outside rules remain effective while the gateway process is absent.

The failure suite creates an owned sentinel namespace without the expected firewall ownership label.
The runner rejects it and preserves its UID and sentinel object.
A separate injected failure stops installation after IPv4 rules are active.
Cleanup removes that run's guest, namespace, and partial IPv4 and IPv6 chains.
If namespace cleanup fails, the runner retains the outside fence.

Review found and corrected namespace cleanup ownership, partial installation cleanup, a buffered CONNECT response race, and a misleading SNI negative.
The final replay uses frozen scripts to avoid changing Bash source during execution.

## Architecture decisions

Use a firewall adapter with an outside datapath fence and explicit protocol capabilities.
Keep domain inspection distinct from opaque IP and port authority.
Resolve protected destinations after DNS, not only before hostname authorization.
Bind control transport exceptions to trusted relay endpoints and connection direction.
Gate untrusted command start on observed fence readiness.
Keep enforcement active until guest disposal is verified.
The shared helper binds the actual Pod UID to its CRI allocation and matching QEMU process.
It removes packet rules only after those recorded resources are absent.
Unverified disposal retains enforcement and returns an error.

Production needs a durable privileged node agent or a supported CNI adapter for these responsibilities.
It also needs concurrent lifecycle ownership, multi-node and routing conformance, bounded resource use, and persistent node decision audit.
Gateway decision logs and packet counters do not establish complete network audit coverage.
The prototype does not establish complete tenant isolation or prove resistance to every kernel or protocol attack.

## Evidence and cleanup

The [summary](../../.prototype-results/firewall/summary.json) records the profile and exercised paths.
The [audit](../../.prototype-results/firewall/audit.jsonl) records gateway allow and deny decisions.
The [failure summary](../../.prototype-results/firewall/failure-summary.json) records namespace and partial-rule cleanup assertions.
The [run log](../../.prototype-results/firewall/run.log) captures the live matrix.
Source, certificates, and fence records remain in ignored private state.
The successful runner deletes its namespace and removes its own packet chains.
The final process audit found stale administration port-forwards because the runner tracked wrapper shell PIDs.
The launcher now tracks kubectl directly, and a repeated full Make target left no stale forward.
It changes no unrelated cluster, host service, or global CNI configuration.
