# Investigation workflow prototype

Question: which evidence separates a validated candidate from a failed or inconclusive investigation?

Run `make prototype-investigation` from the repository root.
The program creates deliberately vulnerable local HTTP fixtures with synthetic document data.
It reproduces an authorization error against three fresh server instances.
It repeats the same input against candidate fixtures and compares baseline behavior.

The scenarios include a working patch, unchanged vulnerability, broken application, unavailable candidate, timeout, and non-vulnerable original.
A validated candidate becomes ready for review.
It does not receive publication authority automatically.

Fresh HTTP servers here do not establish independent VM isolation.
The prototype uses no model and makes no claim about vulnerability discovery quality.
