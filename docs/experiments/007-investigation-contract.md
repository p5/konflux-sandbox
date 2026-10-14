# Investigation evidence and candidate outcomes

Date: 14 October 2026.

Question: which evidence distinguishes a validated candidate from an inconclusive or failed investigation?

Run `make prototype-investigation`.
The prototype uses deliberately vulnerable local HTTP fixtures with synthetic document data.
It requires no model and contacts no external target.

## Executed sequence

The original fixture lets one synthetic user read another user's document.
The fixed fixture rejects that request.
The baseline includes an authorized read, an unauthenticated request, and a missing document.

Each reproduction group uses three fresh HTTP server instances.
The original and candidate receive the same reproduction request.
Regression checks compare status and response body digest with the baseline.
Each observation group must contain its required evidence.

## Results

| Scenario | Outcome | Ready for review |
| --- | --- | --- |
| Fixed authorization with preserved baseline | ValidatedCandidate | Yes |
| Candidate still returns another user's document | CandidateStillVulnerable | No |
| Candidate rejects every request | CandidateBehaviorUnexpected | No |
| Candidate breaks authorized response status | Regression | No |
| Candidate changes authorized content while retaining HTTP 200 | Regression | No |
| Candidate evidence group absent | Inconclusive | No |
| Candidate unavailable | Inconclusive | No |
| Candidate times out | Inconclusive | No |
| Original finding cannot reproduce | OriginalNotReproduced | No |

All nine scenarios produced the expected classification.
No scenario automatically received publication authority.

## Decisions

- Require reproduction evidence against the original before accepting candidate evidence.
- Distinguish failed infrastructure from a failed reproduction.
- Reject missing evidence instead of accepting an empty observation group.
- Compare baseline behavior, including content where relevant.
- Keep candidate validation separate from authorized review and publication.
- Retain source, environment, target version, and reproduction identity in the production evidence model.

## Limits

Fresh local HTTP servers do not establish independent VM isolation.
The separate runtime prototype demonstrates VM execution and cleanup.
This experiment does not evaluate discovery quality, model behavior, or exploit coverage.
Its fixed baseline does not replace application-specific tests or contextual review.

Evidence remains under `.prototype-results/investigation.log` or the aggregate `.prototype-results/local.log`.
