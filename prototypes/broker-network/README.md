# Broker destination enforcement fixture

This throwaway fixture checks destination controls on credential-bearing broker operations.
It uses one actual Kata guest and a token-free ordinary broker Pod.
All origins, DNS, credentials, and certificates are local fixtures.

```sh
make -C prototypes/broker-network run
```

The dedicated VM cluster must already contain Kata and the runtime prototype image.
The Make target builds its own binary and the shared firewall binary.
It loads one local image into the explicit private Kind cluster.

## Network path

```text
Kata guest
  → outside packet fence
  → guest gateway, explicit broker IP:8443 CONNECT only
  → mTLS broker, actual guest UID and operation grant
  → outside broker packet fence
  → broker egress gateway, resolved destination profile
  → authenticated local origin
```

The guest gateway carries opaque TLS and never receives the upstream credential.
The broker verifies the guest's short-lived execution certificate and exact grant identity.
It accepts only fixed operation aliases, the permitted action, and the bound profile digest.
It injects a random synthetic credential outside the guest.
The egress gateway independently applies the destination profile.
The operation grant and destination profile must both permit the request.

The broker's incoming exception accepts only the guest gateway at TCP port 8443.
Its outgoing exception permits only matching replies and its egress gateway at TCP port 8080.
Both packet fences also reject IPv6.
The shared helper records actual Pod and runtime allocation identities before admission.
Cleanup removes those fences only after verified allocation disposal.

## Scenarios

The suite checks permitted HTTP and inspected HTTPS with origin credential confirmation.
It rejects another operation, profile identity, and destination outside the operation grant.
It also rejects a grant-permitted destination outside the network profile.
It denies redirected credential use, protected addresses, and DNS rebinding.
Direct guest and direct broker origin connections have positive baselines before fencing.
Those same connections fail after fencing.

The suite opens actual upstream streams before grant and profile revocation.
Each revocation must close the stream within three seconds.
The origin must independently observe cancellation.
Deleting either gateway must leave its protected path closed.

Origin counters record accepted and rejected credential-bearing requests by hostname.
Forbidden and redirected destinations must receive no request.
Captures must contain no synthetic upstream credential value.

## Limits

This fixture uses trusted host enrollment and static local grant configuration.
Its budgets count operations and its deadlines bound request contexts.
The earlier broker experiment separately exercises budget races and expired grants.
This fixture does not establish provider cost accounting or durable grant recovery.

The trusted egress gateway can read credential-bearing HTTP and inspected HTTPS.
That gateway belongs inside the trusted credential boundary.
The suite does not test a real provider, federated identity, multi-tenant broker, or production network adapter.
Its three-second revocation assertion applies only to the measured local environment.

State, keys, and captures stay in ignored `.state/`, `.build/`, and `evidence/` directories.
The runner removes only its newly created namespace and its recorded packet fences.
The [experiment report](../../docs/experiments/016-broker-network.md) records the measured result.
