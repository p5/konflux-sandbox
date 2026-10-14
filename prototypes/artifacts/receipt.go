package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type identity struct {
	Request     string `json:"request"`
	Attempt     int    `json:"attempt"`
	Source      string `json:"source"`
	Check       string `json:"check"`
	Environment string `json:"environment"`
	Profile     string `json:"profile"`
}

type enforcement struct {
	Profile     string `json:"profile"`
	Runtime     string `json:"runtime"`
	Egress      string `json:"egress"`
	Credentials string `json:"credentials"`
	Observer    string `json:"observer"`
}

type receipt struct {
	Identity identity    `json:"identity"`
	Issued   time.Time   `json:"issued"`
	Expires  time.Time   `json:"expires"`
	Result   string      `json:"result"`
	Observed enforcement `json:"observed"`
}

type envelope struct {
	Issuer    string `json:"issuer"`
	Payload   []byte `json:"payload"`
	Signature []byte `json:"signature"`
}

func signed(r receipt, issuer string, key ed25519.PrivateKey) envelope {
	b, err := json.Marshal(r)
	must(err)
	return envelope{Issuer: issuer, Payload: b, Signature: ed25519.Sign(key, b)}
}

func verify(e envelope, trusted map[string]ed25519.PublicKey, expected identity, now, deadline time.Time) (receipt, error) {
	var r receipt
	key, ok := trusted[e.Issuer]
	if !ok || !ed25519.Verify(key, e.Payload, e.Signature) {
		return r, errors.New("untrusted issuer or invalid signature")
	}
	if e.Issuer != "supervisor" {
		return r, errors.New("issuer cannot attest remote enforcement")
	}
	if err := json.Unmarshal(e.Payload, &r); err != nil {
		return r, err
	}
	if r.Identity != expected {
		return r, errors.New("execution identity mismatch")
	}
	if r.Issued.After(now.Add(5*time.Second)) || r.Issued.Before(now.Add(-2*time.Minute)) || !r.Expires.After(now) || r.Expires.After(deadline) || !r.Expires.After(r.Issued) {
		return r, errors.New("receipt freshness invalid")
	}
	if r.Observed.Profile != expected.Profile || r.Observed.Runtime != "kata" || r.Observed.Egress != "deny-all" || r.Observed.Credentials != "none-mounted" || r.Observed.Observer != "trusted-supervisor" {
		return r, errors.New("required observed enforcement missing or mismatched")
	}
	if r.Result != "PASS" && r.Result != "FAIL" {
		return r, errors.New("result inconclusive")
	}
	return r, nil
}

func runReceipts(state string) {
	must(os.MkdirAll(state, 0700))
	now := time.Now().UTC().Truncate(time.Second)
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	_, guestKey, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	dispatchPub, dispatchKey, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	trusted := map[string]ed25519.PublicKey{"supervisor": pub, "dispatcher": dispatchPub}
	expected := identity{Request: "checkrun-uid-1", Attempt: 2, Source: digest([]byte("synthetic source")), Check: digest([]byte("synthetic check")), Environment: digest([]byte("synthetic environment")), Profile: digest([]byte("synthetic enforced profile"))}
	valid := receipt{Identity: expected, Issued: now, Expires: now.Add(time.Minute), Result: "PASS", Observed: enforcement{Profile: expected.Profile, Runtime: "kata", Egress: "deny-all", Credentials: "none-mounted", Observer: "trusted-supervisor"}}
	deadline := now.Add(time.Minute)
	results := map[string]any{"cryptographic_signatures": "Ed25519; ephemeral in-memory synthetic key", "semantics": "proposed extension; not existing Conforma policy", "observed_enforcement": "signed supervisor claim; not independent runtime measurement"}
	accepted, err := verify(signed(valid, "supervisor", key), trusted, expected, now, deadline)
	must(err)
	results["valid_signed_scoped_receipt_permitted"] = accepted.Result == "PASS"
	cases := map[string]receipt{}
	wrong := valid
	wrong.Identity.Source = "sha256:wrong"
	cases["wrong_source"] = wrong
	wrong = valid
	wrong.Identity.Check = "sha256:wrong"
	cases["wrong_check"] = wrong
	wrong = valid
	wrong.Identity.Environment = "sha256:wrong"
	cases["wrong_environment"] = wrong
	wrong = valid
	wrong.Identity.Profile = "sha256:wrong"
	cases["wrong_requested_profile"] = wrong
	wrong = valid
	wrong.Identity.Request = "different-request"
	cases["wrong_request"] = wrong
	wrong = valid
	wrong.Identity.Attempt = 1
	cases["stale_attempt"] = wrong
	wrong = valid
	wrong.Expires = now.Add(-time.Second)
	cases["expired"] = wrong
	wrong = valid
	wrong.Expires = deadline.Add(time.Second)
	cases["beyond_deadline"] = wrong
	wrong = valid
	wrong.Issued = now.Add(-3 * time.Minute)
	cases["old_receipt"] = wrong
	wrong = valid
	wrong.Observed = enforcement{}
	cases["requested_profile_only"] = wrong
	wrong = valid
	wrong.Observed.Runtime = "ordinary-container"
	cases["wrong_observed_runtime"] = wrong
	wrong = valid
	wrong.Observed.Egress = "allow-all"
	cases["wrong_observed_egress"] = wrong
	wrong = valid
	wrong.Observed.Credentials = "mounted-token"
	cases["guest_credentials"] = wrong
	wrong = valid
	wrong.Observed.Observer = "guest"
	cases["guest_reported_enforcement"] = wrong
	wrong = valid
	wrong.Result = "TIMEOUT"
	cases["inconclusive_result"] = wrong
	for name, r := range cases {
		_, err := verify(signed(r, "supervisor", key), trusted, expected, now, deadline)
		if err == nil {
			panic("negative receipt permitted: " + name)
		}
		results["rejected_"+name] = err.Error()
	}
	_, err = verify(signed(valid, "guest", guestKey), trusted, expected, now, deadline)
	if err == nil {
		panic("guest issuer permitted")
	}
	results["rejected_untrusted_issuer"] = err.Error()
	dispatch := valid
	dispatch.Observed = enforcement{}
	_, err = verify(signed(dispatch, "dispatcher", dispatchKey), trusted, expected, now, deadline)
	if err == nil {
		panic("dispatch-only evidence permitted")
	}
	results["rejected_signed_dispatch_only"] = err.Error()
	_, err = verify(signed(valid, "dispatcher", dispatchKey), trusted, expected, now, deadline)
	if err == nil {
		panic("dispatcher enforcement claim permitted")
	}
	results["rejected_dispatcher_claiming_enforcement"] = err.Error()
	impersonated := signed(valid, "dispatcher", dispatchKey)
	impersonated.Issuer = "supervisor"
	_, err = verify(impersonated, trusted, expected, now, deadline)
	if err == nil {
		panic("issuer substitution permitted")
	}
	results["rejected_issuer_substitution"] = err.Error()
	tampered := signed(valid, "supervisor", key)
	tampered.Payload = append(tampered.Payload, ' ')
	_, err = verify(tampered, trusted, expected, now, deadline)
	if err == nil {
		panic("tampered signature permitted")
	}
	results["rejected_tampering"] = err.Error()
	failed := valid
	failed.Result = "FAIL"
	accepted, err = verify(signed(failed, "supervisor", key), trusted, expected, now, deadline)
	must(err)
	results["valid_failure_is_evidence_but_cannot_promote"] = accepted.Result != "PASS"
	b, err := json.MarshalIndent(signed(valid, "supervisor", key), "", "  ")
	must(err)
	must(os.WriteFile(filepath.Join(state, "signed-receipt.json"), b, 0600))
	b, err = json.MarshalIndent(results, "", "  ")
	must(err)
	fmt.Println(string(b))
}
