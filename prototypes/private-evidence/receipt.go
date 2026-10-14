package evidence

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"time"
)

type Grant struct {
	GuestUID      string    `json:"guest_uid"`
	ExpiresAt     time.Time `json:"expires_at"`
	SourceDigest  string    `json:"source_digest"`
	ToolDigest    string    `json:"tool_digest"`
	ProfileDigest string    `json:"profile_digest"`
	Backend       string    `json:"backend"`
}

type Receipt struct {
	Version         string            `json:"version"`
	Owner           string            `json:"owner"`
	Request         string            `json:"request"`
	Attempt         int               `json:"attempt"`
	GuestUID        string            `json:"guest_uid"`
	SourceDigest    string            `json:"source_digest"`
	ToolDigest      string            `json:"tool_digest"`
	ProfileDigest   string            `json:"profile_digest"`
	Backend         string            `json:"backend"`
	IssuedAt        time.Time         `json:"issued_at"`
	CompletedAt     time.Time         `json:"completed_at"`
	RetainUntil     time.Time         `json:"retain_until"`
	Outcome         string            `json:"outcome"`
	Observed        map[string]string `json:"observed"`
	LogsDigest      string            `json:"logs_digest"`
	ArtifactDigests map[string]string `json:"artifact_digests"`
}

type Envelope struct {
	Issuer    string `json:"issuer"`
	Payload   []byte `json:"payload"`
	Signature []byte `json:"signature"`
}

func Digest(b []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(b)) }

func Sign(body Receipt, issuer string, key ed25519.PrivateKey) (Envelope, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return Envelope{}, err
	}
	return Envelope{Issuer: issuer, Payload: b, Signature: ed25519.Sign(key, append([]byte("konflux-sandbox.execution-receipt.v1\x00"), b...))}, nil
}

func Verify(e Envelope, keys map[string]ed25519.PublicKey) (Receipt, error) {
	var body Receipt
	key, ok := keys[e.Issuer]
	if !ok || !ed25519.Verify(key, append([]byte("konflux-sandbox.execution-receipt.v1\x00"), e.Payload...), e.Signature) {
		return body, errors.New("untrusted supervisor or invalid receipt signature")
	}
	if err := json.Unmarshal(e.Payload, &body); err != nil {
		return body, err
	}
	if body.Version != "konflux-sandbox.execution.v1" {
		return body, errors.New("unsupported receipt version")
	}
	return body, nil
}

func bindReceipt(body Receipt, owner, request string, attempt int, g Grant, logs string, artifacts map[string]string, now time.Time) error {
	if body.Owner != owner || body.Request != request || body.Attempt != attempt || body.GuestUID != g.GuestUID || body.SourceDigest != g.SourceDigest || body.ToolDigest != g.ToolDigest || body.ProfileDigest != g.ProfileDigest || body.Backend != g.Backend || !body.RetainUntil.Equal(g.ExpiresAt) {
		return errors.New("receipt grant identity mismatch")
	}
	if body.LogsDigest != logs || !maps.Equal(body.ArtifactDigests, artifacts) {
		return errors.New("receipt content digest mismatch")
	}
	if body.IssuedAt.After(now.Add(5*time.Second)) || body.IssuedAt.Before(now.Add(-5*time.Minute)) || body.CompletedAt.After(body.IssuedAt) || body.CompletedAt.Before(now.Add(-5*time.Minute)) {
		return errors.New("receipt timestamps invalid")
	}
	if body.Outcome != "Passed" && body.Outcome != "CheckFailed" && body.Outcome != "Cancelled" && body.Outcome != "TimedOut" {
		return errors.New("receipt outcome missing")
	}
	if body.Observed["pod_uid"] != g.GuestUID {
		return errors.New("observed execution identity missing")
	}
	if g.Backend != "local-producer-fixture" {
		if body.Observed["runtime_class"] != "kata-prototype" || body.Observed["guest_kernel"] == "" || body.Observed["node_kernel"] == "" || body.Observed["guest_kernel"] == body.Observed["node_kernel"] || body.Observed["profile_digest"] != g.ProfileDigest {
			return errors.New("observed runtime or profile evidence missing")
		}
	}
	return nil
}
