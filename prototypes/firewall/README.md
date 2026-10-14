# Domain and IP firewall prototype

This throwaway prototype asks whether one outside-guest enforcement pattern can protect finite tasks and interactive sessions.
It uses a dedicated HTTP/S gateway and node-side packet rules for each guest interface.

Run from the repository root:

```sh
make -C prototypes/firewall run
```

The command requires the existing Kata Kind cluster, its runtime image, Docker, Go, kubectl, jq, curl, and ripgrep.
It uses only foundation-firewall-prototype and the dedicated VM node.
It creates a named service account without token automount.
It removes its namespace and packet rules after execution.
The failure scenarios verify namespace ownership rejection and partial rule cleanup.

## Supported prototype profile

- IPv4 TCP through a dedicated gateway.
- HTTP/1.1 domain rules and inspected HTTP/1.1 over TLS 1.3.
- Exact domain names and a wildcard for exactly one subordinate label.
- Explicit IP or CIDR rules with destination ports for opaque TCP CONNECT.
- Gateway-controlled DNS without address caching or upstream connection reuse.
- Protected address rejection after DNS resolution.
- Outside-guest IPv6 denial and rejection of IPv6-enabled profiles.

The HTTPS domain mode terminates TLS at the trusted gateway and checks CONNECT, SNI, HTTP Host, and upstream certificates.
Clients must trust the prototype gateway CA for that mode.
Certificate-pinned clients and opaque domain tunnels require another supported profile.
Explicit IP grants authorize that IP and port without claiming hostname restrictions inside their opaque traffic.
UDP profiles and unknown profile fields fail validation.

## Shared enforcer fixture

```sh
bash prototypes/firewall/fence.sh install KUBECONFIG RECORD_JSON NAMESPACE POD GATEWAY_IP [CONTROL_RELAY_IP]
bash prototypes/firewall/fence.sh remove KUBECONFIG RECORD_JSON
```

The helper accepts only the firewall, consumer, and broker-network fixture namespaces in the dedicated VM cluster.
It records the actual Pod UID, CRI allocation ID, RuntimeClass, node-side interface, packet chains, and gateway.
Kata records also identify the matching QEMU process.
The record contains any control relay exception and observed readiness.
It permits only workload traffic to the gateway's TCP port 8080.
An optional control relay permits incoming TLS on guest port 8443 and the corresponding connection replies.
It does not permit arbitrary guest-initiated established connections.

Start untrusted commands only after the helper records readiness.
Delete the guest before removing its fence.
Removal requires the recorded Pod UID, ready CRI allocation, and matching QEMU process to be absent.
The helper waits up to sixty seconds and records runtimeRemovalVerified only after successful checks.
Keep the fence when cleanup cannot establish guest removal.

## Evidence

Captures remain under ignored .prototype-results/firewall/ and .prototype-state/firewall/.
Private CA keys remain in ignored state and trusted fixture Pods.
Guests receive only the public CA.
The gateway audit records policy decisions; packet counters record node-side rejection activity.
Production needs persistent node-agent ownership, audit, lifecycle recovery, and supported-node conformance.

See [experiment 011](../../docs/experiments/011-firewall-enforcement.md).
