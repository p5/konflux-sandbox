# Credential broker prototype

Question: which grant checks and request rules prevent credential disclosure and unauthorized upstream operations?

Run `make prototype-broker` from the repository root.
The program starts local HTTP servers with synthetic identities and a synthetic upstream secret.
It exercises ownership, method scope, destination selection, expiry, revocation, redirects, body limits, and concurrent budgets.

The proxy injects the upstream credential only on the configured destination.
It cancels an in-flight request when its grant is revoked.
Guest responses never contain the upstream secret in these fixtures.

This prototype does not establish Kubernetes identity, TLS authentication, or network isolation.
The runtime prototype evaluates network enforcement separately.
