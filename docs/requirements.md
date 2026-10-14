# Foundation requirements

Date: 14 October 2026.
These requirements supersede earlier plans to implement workspace and vulnerability products in this repository.
Each numbered item contains one requirement sentence.

## Scope and execution

1. Provide a shared sandbox foundation that external services can use to build workspaces, checks, vulnerability discovery, and vulnerability investigation.
2. Deliver an optional Konflux extension in p5/konflux-sandbox that preserves existing Konflux APIs and workflows.
3. Expose one execution contract with shared isolation, authorization, profiles, firewall controls, credential grants, artifacts, and evidence.
4. Support finite Tekton execution and interactive sessions through the foundation's interfaces.
5. Leave product controllers, workspace applications, agent reasoning, vulnerability analysis, patch decisions, and review workflows to external services.
6. Accept immutable source artifacts that identify selected working-tree bytes, file modes, and symlinks.
7. Bind each attempt to its owner, immutable inputs, environment, resolved profile, policy revision, and execution identity.
8. Enforce approved VM isolation and reject execution when required runtime or policy enforcement is unavailable.
9. Enforce administrator-controlled resource, duration, output, storage, network, and external-operation limits.
10. Authenticate and authorize submission, observation, attachment, cancellation, file transfer, and artifact access for each owner.
11. Keep upstream credentials, signing keys, and general Kubernetes credentials outside untrusted guests.
12. Expose scoped, revocable credential grants through a separate broker with destination, operation, deadline, and budget controls.
13. Return structured execution outcomes, diagnostic references, artifact identities, and independent cleanup status.
14. Propagate cancellation and deadlines to workloads and remove resources according to the retention policy.
15. Recover owned resources after controller restarts and report uncertain execution without silently repeating commands.
16. Record supervisor-observed execution evidence separately from guest-reported results and expose verification interfaces to consumers.
17. Expose authenticated command streaming, terminal attachment, file transfer, persistent storage, and source export as reusable capabilities.
18. Protect artifacts, logs, and evidence through owner access controls and explicit retention rules.
19. Expose supported Konflux artifact, result, and policy integration interfaces without automatically promoting exploratory runs into builds or releases.
20. Publish capability and compatibility information that lets consumers detect unsupported operations before execution.
21. Run local verification through Makefiles with pinned dependencies, explicit cluster selection, and real runtime conformance checks.
22. Keep repository CI outside scope.

## Outbound firewall

1. Deny outbound workload traffic by default and permit only destinations authorized by the resolved execution profile.
2. Support explicit domain names, IP addresses, and CIDR ranges with destination port and transport protocol restrictions.
3. Define exact domain matching and any wildcard matching explicitly without implicit permission for parent domains or unrelated subdomains.
4. Enforce firewall rules outside the guest across native Tekton execution and interactive session paths.
5. Use controlled DNS resolution and handle address changes, expiry, and DNS rebinding without expanding permitted destination scope.
6. Define hostname enforcement guarantees for each supported protocol, including destinations that share IP addresses.
7. Block unauthorized direct IP connections, alternate DNS paths, redirects, and protocol paths that bypass domain restrictions.
8. Cover IPv4 and IPv6 or disable unsupported address families before admitting execution.
9. Deny cloud metadata, host, control-plane, unrelated tenant, and unrelated cluster destinations under the protected destination policy.
10. Expose authorized policy restriction, revocation, and readiness observation to consumers without letting them exceed administrator permissions.
11. Record firewall decisions with execution identity, destination, policy revision, timestamp, and rejection reason.
12. Reject unsupported profiles and stop affected network access when enforcement or required policy state becomes unavailable.
13. Apply destination controls to broker-originated operations as well as direct guest connections.
14. Stop new connections and terminate existing connections within a documented bounded deadline after policy revocation.

An allowed destination can still receive workload data.
Destination permission does not establish safe application behavior at that destination.
The broker supplies additional operation restrictions where credentials or sensitive operations require them.

## First deliverable

Provide a minimal execution client and fixture that submit immutable source and run a bounded command in a fresh guest.
Include domain and IP firewall enforcement, cancellation, deadlines, structured evidence, and verified cleanup in its acceptance criteria.
Use a check fixture to demonstrate the interface without implementing a check product.
Expose interactive capabilities through the same foundation contract as their implementation becomes available.

## Current choices and open decisions

Native Tekton with Kata and Agent Sandbox remain implementation choices subject to compatibility evidence.
Remote dispatch remains optional.
The initial firewall pattern combines a trusted gateway with an outside-guest packet fence.
The demonstrated profile permits inspected HTTP/S domain traffic and explicit IPv4 TCP IP or CIDR grants.
UDP, IPv6 access, opaque domain tunnels, and unsupported policy fields fail admission.
Production still needs a durable node agent or supported CNI adapter, concurrent ownership, and multi-node conformance.
The [foundation experiments](experiments/011-firewall-enforcement.md) record the tested guarantees and limits.
Full VM memory restoration, shared warm snapshots, and automatic check-result reuse remain deferred.
External product services own any authoritative verdict reuse or publication decisions.
