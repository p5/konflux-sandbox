package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"time"
)

type observation struct {
	Status     int    `json:"status"`
	BodyDigest string `json:"bodyDigest"`
	Reproduced bool   `json:"reproduced"`
	Error      string `json:"error"`
}

type report struct {
	Scenario         string        `json:"scenario"`
	Baseline         []observation `json:"baseline"`
	Original         []observation `json:"originalReproductions"`
	Candidate        []observation `json:"candidateReproductions"`
	Regression       []observation `json:"candidateRegression"`
	Outcome          string        `json:"outcome"`
	ReadyForReview   bool          `json:"readyForReview"`
	PublicationGrant bool          `json:"publicationGrant"`
}

func fixture(mode string) *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /documents/{id}", func(w http.ResponseWriter, r *http.Request) {
		actor := r.Header.Get("X-Prototype-Actor")
		if actor == "" || mode == "deny-all" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		if id != "alice" && id != "bob" {
			http.NotFound(w, r)
			return
		}
		if id != actor && mode == "timeout" {
			<-r.Context().Done()
			return
		}
		if id != actor && (mode == "fixed" || mode == "regression" || mode == "wrong-content") {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if mode == "regression" {
			http.Error(w, "owner request regressed", http.StatusInternalServerError)
			return
		}
		if mode == "wrong-content" {
			_, _ = io.WriteString(w, "wrong-owner-document")
			return
		}
		_, _ = io.WriteString(w, id+"_PRIVATE_FIXTURE")
	})
	return httptest.NewServer(mux)
}

func observe(url, actor string) observation {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	r.Header.Set("X-Prototype-Actor", actor)
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	response, err := client.Do(r)
	if err != nil {
		return observation{Error: "infrastructure-or-timeout"}
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		return observation{Status: response.StatusCode, Error: "response-read-failure"}
	}
	return observation{Status: response.StatusCode, BodyDigest: fmt.Sprintf("sha256:%x", sha256.Sum256(data)), Reproduced: response.StatusCode == 200 && string(data) == "bob_PRIVATE_FIXTURE"}
}

func baseline(mode string) []observation {
	s := fixture(mode)
	defer s.Close()
	return []observation{observe(s.URL+"/documents/alice", "alice"), observe(s.URL+"/documents/alice", ""), observe(s.URL+"/documents/missing", "alice")}
}

func reproduce(mode string) []observation {
	var out []observation
	for range 3 {
		s := fixture(mode)
		if mode == "unavailable" {
			s.Close()
		}
		out = append(out, observe(s.URL+"/documents/bob", "alice"))
		s.Close()
	}
	return out
}

func classify(r report) report {
	for _, group := range [][]observation{r.Baseline, r.Original, r.Candidate, r.Regression} {
		if len(group) != 3 {
			r.Outcome = "Inconclusive"
			return r
		}
		for _, o := range group {
			if o.Error != "" {
				r.Outcome = "Inconclusive"
				return r
			}
		}
	}
	for _, o := range r.Original {
		if !o.Reproduced {
			r.Outcome = "OriginalNotReproduced"
			return r
		}
	}
	for _, o := range r.Candidate {
		if o.Reproduced {
			r.Outcome = "CandidateStillVulnerable"
			return r
		}
		if o.Status != http.StatusForbidden {
			r.Outcome = "CandidateBehaviorUnexpected"
			return r
		}
	}
	for i, o := range r.Regression {
		if o.Status != r.Baseline[i].Status || o.BodyDigest != r.Baseline[i].BodyDigest {
			r.Outcome = "Regression"
			return r
		}
	}
	r.Outcome, r.ReadyForReview = "ValidatedCandidate", true
	return r
}

func main() {
	cases := []struct{ Name, Original, Candidate, Expected string }{
		{"valid-patch", "vulnerable", "fixed", "ValidatedCandidate"},
		{"still-vulnerable", "vulnerable", "vulnerable", "CandidateStillVulnerable"},
		{"denies-all-requests", "vulnerable", "deny-all", "CandidateBehaviorUnexpected"},
		{"owner-request-regression", "vulnerable", "regression", "Regression"},
		{"owner-content-regression", "vulnerable", "wrong-content", "Regression"},
		{"missing-evidence", "vulnerable", "fixed", "Inconclusive"},
		{"candidate-unavailable", "vulnerable", "unavailable", "Inconclusive"},
		{"candidate-timeout", "vulnerable", "timeout", "Inconclusive"},
		{"original-not-vulnerable", "fixed", "fixed", "OriginalNotReproduced"},
	}
	for _, c := range cases {
		r := report{Scenario: c.Name, Baseline: baseline(c.Original), Original: reproduce(c.Original), Candidate: reproduce(c.Candidate), Regression: baseline(c.Candidate)}
		if c.Name == "missing-evidence" {
			r.Candidate = nil
		}
		r = classify(r)
		_ = json.NewEncoder(os.Stdout).Encode(r)
		if r.Outcome != c.Expected || r.PublicationGrant || (r.ReadyForReview != (c.Expected == "ValidatedCandidate")) {
			fmt.Fprintln(os.Stderr, "FAIL:", c.Name)
			os.Exit(1)
		}
	}
	fmt.Printf("PASS %d investigation scenarios; local HTTP fixture, no model or VM-isolation evidence.\n", len(cases))
}
