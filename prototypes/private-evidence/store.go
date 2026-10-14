package evidence

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
)

var component = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
var artifactName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,126}$`)

type scope struct {
	Owner, Request string
	Attempt        int
}
type record struct {
	Grant     Grant
	Logs      []byte
	Artifacts map[string][]byte
	Receipt   []byte
	Sealed    bool
	Expired   bool
	Notify    chan struct{}
}

type Metadata struct {
	Owner           string            `json:"owner"`
	Request         string            `json:"request"`
	Attempt         int               `json:"attempt"`
	Grant           Grant             `json:"grant"`
	LogsDigest      string            `json:"logs_digest"`
	ArtifactDigests map[string]string `json:"artifact_digests"`
	Sealed          bool              `json:"sealed"`
}

type Store struct {
	mu           sync.Mutex
	records      map[scope]*record
	keys         map[string]ed25519.PublicKey
	maxRetention time.Duration
}

func NewStore(keys map[string]ed25519.PublicKey, maxRetention time.Duration) *Store {
	return &Store{records: map[scope]*record{}, keys: keys, maxRetention: maxRetention}
}

func (s *Store) Handler() http.Handler {
	m := http.NewServeMux()
	base := "/v1/owners/{owner}/requests/{request}/attempts/{attempt}"
	m.HandleFunc("POST "+base, s.open)
	m.HandleFunc("GET "+base+"/metadata", s.metadata)
	m.HandleFunc("POST "+base+"/logs", s.appendLogs)
	m.HandleFunc("GET "+base+"/logs", s.logs)
	m.HandleFunc("PUT "+base+"/artifacts/{name}", s.putArtifact)
	m.HandleFunc("GET "+base+"/artifacts/{name}", s.artifact)
	m.HandleFunc("PUT "+base+"/receipt", s.putReceipt)
	m.HandleFunc("GET "+base+"/receipt", s.receipt)
	return m
}

func principal(r *http.Request) (pki.Identity, string, error) {
	if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 || len(r.TLS.PeerCertificates) == 0 {
		return pki.Identity{}, "", errors.New("verified client certificate required")
	}
	for _, role := range []string{"control", "execution"} {
		id, err := pki.Parse(r.TLS.PeerCertificates[0], role)
		if err == nil {
			return id, role, nil
		}
	}
	return pki.Identity{}, "", errors.New("authorized certificate role required")
}

func authorize(w http.ResponseWriter, r *http.Request, control bool) (scope, pki.Identity, bool) {
	id, role, err := principal(r)
	attempt, parseErr := strconv.Atoi(r.PathValue("attempt"))
	sc := scope{Owner: r.PathValue("owner"), Request: r.PathValue("request"), Attempt: attempt}
	if err != nil || parseErr != nil || attempt < 1 || strconv.Itoa(attempt) != r.PathValue("attempt") || !component.MatchString(sc.Owner) || !component.MatchString(sc.Request) || id.Owner != sc.Owner || id.Request != sc.Request || id.Attempt != strconv.Itoa(sc.Attempt) || (control && role != "control") {
		http.Error(w, "evidence scope denied", http.StatusForbidden)
		return scope{}, pki.Identity{}, false
	}
	return sc, id, true
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func body(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, error) {
	return io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
}
func wake(rec *record) { close(rec.Notify); rec.Notify = make(chan struct{}) }

func expire(rec *record, now time.Time) {
	if !rec.Expired && !now.Before(rec.Grant.ExpiresAt) {
		clear(rec.Logs)
		rec.Logs = nil
		for name, b := range rec.Artifacts {
			clear(b)
			delete(rec.Artifacts, name)
		}
		clear(rec.Receipt)
		rec.Receipt = nil
		rec.Expired = true
		wake(rec)
	}
}

func (s *Store) get(w http.ResponseWriter, sc scope, id pki.Identity) *record {
	rec := s.records[sc]
	if rec == nil {
		http.Error(w, "evidence request not found", 404)
		return nil
	}
	if rec.Grant.GuestUID != id.GuestUID {
		http.Error(w, "execution identity denied", 403)
		return nil
	}
	expire(rec, time.Now())
	if rec.Expired {
		http.Error(w, "evidence retention expired", 410)
		return nil
	}
	return rec
}

func (s *Store) open(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	b, err := body(w, r, 8192)
	var g Grant
	if err != nil || json.Unmarshal(b, &g) != nil || g.GuestUID != id.GuestUID || !g.ExpiresAt.After(time.Now()) || g.ExpiresAt.After(time.Now().Add(s.maxRetention)) || g.SourceDigest == "" || g.ToolDigest == "" || g.ProfileDigest == "" || (g.Backend != "local-producer-fixture" && g.Backend != "kata-taskrun" && g.Backend != "agent-sandbox") {
		http.Error(w, "invalid evidence grant", 400)
		return
	}
	g.ExpiresAt = g.ExpiresAt.UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.records[sc]; existing != nil {
		expire(existing, time.Now())
		if existing.Expired {
			http.Error(w, "evidence retention expired", 410)
			return
		}
		if existing.Grant != g {
			http.Error(w, "evidence grant conflicts with prior request", 409)
			return
		}
		writeJSON(w, 200, g)
		return
	}
	s.records[sc] = &record{Grant: g, Artifacts: map[string][]byte{}, Notify: make(chan struct{})}
	writeJSON(w, 201, g)
}

func (s *Store) appendLogs(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, false)
	if !ok {
		return
	}
	b, err := body(w, r, 64<<10)
	if err != nil {
		http.Error(w, "log input limit", 413)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec := s.get(w, sc, id)
	if rec == nil {
		return
	}
	if rec.Sealed {
		http.Error(w, "evidence already sealed", 409)
		return
	}
	if len(rec.Logs)+len(b) > 64<<10 {
		http.Error(w, "log storage limit", 413)
		return
	}
	rec.Logs = append(rec.Logs, b...)
	wake(rec)
	w.WriteHeader(204)
}

func (s *Store) putArtifact(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, false)
	if !ok {
		return
	}
	name := r.PathValue("name")
	if !artifactName.MatchString(name) {
		http.Error(w, "invalid artifact name", 400)
		return
	}
	b, err := body(w, r, 1<<20)
	if err != nil {
		http.Error(w, "artifact input limit", 413)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec := s.get(w, sc, id)
	if rec == nil {
		return
	}
	if rec.Sealed {
		http.Error(w, "evidence already sealed", 409)
		return
	}
	if _, exists := rec.Artifacts[name]; exists {
		http.Error(w, "artifact is immutable", 409)
		return
	}
	if len(rec.Artifacts) >= 4 {
		http.Error(w, "artifact count limit", 413)
		return
	}
	rec.Artifacts[name] = bytes.Clone(b)
	wake(rec)
	writeJSON(w, 201, map[string]string{"digest": Digest(b)})
}

func snapshot(sc scope, rec *record) Metadata {
	artifacts := map[string]string{}
	for name, b := range rec.Artifacts {
		artifacts[name] = Digest(b)
	}
	return Metadata{Owner: sc.Owner, Request: sc.Request, Attempt: sc.Attempt, Grant: rec.Grant, LogsDigest: Digest(rec.Logs), ArtifactDigests: artifacts, Sealed: rec.Sealed}
}

func (s *Store) metadata(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec := s.get(w, sc, id)
	if rec == nil {
		return
	}
	writeJSON(w, 200, snapshot(sc, rec))
}

func (s *Store) artifact(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	s.mu.Lock()
	rec := s.get(w, sc, id)
	if rec == nil {
		s.mu.Unlock()
		return
	}
	b, ok := rec.Artifacts[r.PathValue("name")]
	if !ok {
		s.mu.Unlock()
		http.NotFound(w, r)
		return
	}
	b = bytes.Clone(b)
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Content-Digest", Digest(b))
	_, _ = w.Write(b)
}

func (s *Store) logs(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	follow := r.URL.Query().Get("follow") == "true"
	offset := 0
	started := false
	for {
		s.mu.Lock()
		var rec *record
		if started {
			rec = s.records[sc]
			expire(rec, time.Now())
			if rec.Expired {
				s.mu.Unlock()
				w.Header().Set("X-Evidence-Stream-State", "expired")
				return
			}
		} else {
			rec = s.get(w, sc, id)
		}
		if rec == nil {
			s.mu.Unlock()
			return
		}
		b := bytes.Clone(rec.Logs[offset:])
		offset = len(rec.Logs)
		done := rec.Sealed
		notify := rec.Notify
		expires := rec.Grant.ExpiresAt
		s.mu.Unlock()
		if !started {
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Header().Set("Trailer", "X-Evidence-Stream-State")
			w.WriteHeader(200)
			started = true
		}
		if _, err := w.Write(b); err != nil {
			return
		}
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		if !follow || done {
			state := "snapshot"
			if done {
				state = "sealed"
			}
			w.Header().Set("X-Evidence-Stream-State", state)
			return
		}
		if r.TLS.PeerCertificates[0].NotAfter.Before(expires) {
			expires = r.TLS.PeerCertificates[0].NotAfter
		}
		select {
		case <-r.Context().Done():
			return
		case <-notify:
		case <-time.After(time.Until(expires)):
			w.Header().Set("X-Evidence-Stream-State", "expired")
			return
		}
	}
}

func (s *Store) putReceipt(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	b, err := body(w, r, 64<<10)
	var e Envelope
	if err != nil || json.Unmarshal(b, &e) != nil {
		http.Error(w, "invalid receipt envelope", 400)
		return
	}
	receipt, err := Verify(e, s.keys)
	if err != nil {
		http.Error(w, err.Error(), 422)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec := s.get(w, sc, id)
	if rec == nil {
		return
	}
	if rec.Sealed {
		http.Error(w, "evidence already sealed", 409)
		return
	}
	meta := snapshot(sc, rec)
	if err := bindReceipt(receipt, sc.Owner, sc.Request, sc.Attempt, rec.Grant, meta.LogsDigest, meta.ArtifactDigests, time.Now()); err != nil {
		http.Error(w, err.Error(), 422)
		return
	}
	rec.Receipt = bytes.Clone(b)
	rec.Sealed = true
	wake(rec)
	w.WriteHeader(201)
}

func (s *Store) receipt(w http.ResponseWriter, r *http.Request) {
	sc, id, ok := authorize(w, r, true)
	if !ok {
		return
	}
	s.mu.Lock()
	rec := s.get(w, sc, id)
	if rec == nil {
		s.mu.Unlock()
		return
	}
	if !rec.Sealed {
		s.mu.Unlock()
		http.NotFound(w, r)
		return
	}
	b := bytes.Clone(rec.Receipt)
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}

func (s *Store) Sweep(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, rec := range s.records {
		expire(rec, now)
	}
}
func (s *Store) Bytes() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	total := 0
	for _, rec := range s.records {
		total += len(rec.Logs) + len(rec.Receipt)
		for _, b := range rec.Artifacts {
			total += len(b)
		}
	}
	return total
}
func (s *Store) RunJanitor(ctx context.Context) {
	ticks := time.Tick(20 * time.Millisecond)
	for {
		select {
		case <-ctx.Done():
			return
		case t := <-ticks:
			s.Sweep(t)
		}
	}
}

func QuietServerErrorLog() *log.Logger { return log.New(io.Discard, "", 0) }
