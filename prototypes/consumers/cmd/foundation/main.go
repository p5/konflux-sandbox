package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
	evidence "github.com/p5/konflux-sandbox/prototypes/private-evidence"
)

type Config struct {
	SourceDigest  string `json:"sourceDigest"`
	ProfileDigest string `json:"profileDigest"`
	ToolDigest    string `json:"toolDigest"`
}
type Spec struct {
	Kind          string `json:"kind"`
	SourceDigest  string `json:"sourceDigest"`
	ProfileDigest string `json:"profileDigest"`
}
type Record struct {
	Owner        string            `json:"owner"`
	Request      string            `json:"request"`
	Spec         Spec              `json:"spec"`
	Status       string            `json:"status"`
	GuestUID     string            `json:"guestUID"`
	Expires      time.Time         `json:"expires"`
	Control      pki.Files         `json:"-"`
	Backend      string            `json:"backend"`
	Attempt      int               `json:"attempt"`
	ToolDigest   string            `json:"toolDigest"`
	NamespaceUID string            `json:"namespaceUID"`
	Binding      map[string]string `json:"binding,omitempty"`
	Cleanup      string            `json:"cleanup,omitempty"`
}
type Foundation struct {
	mu      sync.Mutex
	state   string
	config  Config
	records map[string]*Record
	active  string
	key     ed25519.PrivateKey
	pub     ed25519.PublicKey
	address string
	durable bool
}

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func readJSON(p string, v any)  { b, e := os.ReadFile(p); must(e); must(json.Unmarshal(b, v)) }
func writeJSON(p string, v any) { b, e := json.Marshal(v); must(e); must(os.WriteFile(p, b, 0600)) }
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func (f *Foundation) backend(operation, request, kind string) error {
	c := exec.Command("bash", "backend.sh", operation, f.state, request, kind)
	out, e := c.CombinedOutput()
	must(os.WriteFile(filepath.Join(f.state, request+"-"+operation+".log"), out, 0600))
	if e != nil {
		return fmt.Errorf("backend %s failed: %w", operation, e)
	}
	return nil
}
func (f *Foundation) principal(w http.ResponseWriter, r *http.Request) (pki.Identity, bool) {
	if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 {
		http.Error(w, "identity required", 403)
		return pki.Identity{}, false
	}
	id, e := pki.Parse(r.TLS.PeerCertificates[0], "control")
	if e != nil || id.GuestUID != "pending" || id.Attempt != "1" {
		http.Error(w, "consumer identity denied", 403)
		return id, false
	}
	return id, true
}
func (f *Foundation) request(w http.ResponseWriter, r *http.Request) {
	id, ok := f.principal(w, r)
	if !ok {
		return
	}
	request := r.PathValue("request")
	if request != id.Request || (request != "finite" && request != "session") {
		http.Error(w, "request scope denied", 403)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	rec := f.records[request]
	if rec != nil && rec.Owner != id.Owner {
		http.Error(w, "owner denied", 403)
		return
	}
	switch r.Method {
	case http.MethodPost:
		var spec Spec
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&spec) != nil {
			http.Error(w, "invalid request", 400)
			return
		}
		if rec != nil {
			if rec.Spec != spec {
				http.Error(w, "immutable request conflict", 409)
				return
			}
			respond(w, 200, rec)
			return
		}
		if spec.SourceDigest != f.config.SourceDigest || spec.ProfileDigest != f.config.ProfileDigest || (spec.Kind != "finite" && spec.Kind != "session") || id.Owner != "alice" {
			http.Error(w, "unsupported source, profile, backend or owner", 422)
			return
		}
		if f.active != "" {
			http.Error(w, "single guest capacity exhausted", 429)
			return
		}
		rec = &Record{Owner: id.Owner, Request: request, Spec: spec, Status: "Provisioning", Attempt: 1, ToolDigest: f.config.ToolDigest}
		namespace, e := os.ReadFile(filepath.Join(f.state, "namespace-uid"))
		must(e)
		rec.NamespaceUID = string(namespace)
		f.records[request] = rec
		f.active = request
		f.save(rec)
		if e := f.backend("start", request, spec.Kind); e != nil {
			rec.Status = "CleanupPending"
			if stopErr := f.backend("stop", request, spec.Kind); stopErr == nil {
				rec.Status = "Failed"
				f.active = ""
			}
			http.Error(w, e.Error(), 500)
			return
		}
		var child struct {
			GuestUID string `json:"guestUID"`
			Backend  string `json:"backend"`
		}
		readJSON(filepath.Join(f.state, request, "backend.json"), &child)
		rec.GuestUID = child.GuestUID
		rec.Backend = child.Backend
		if f.durable {
			readJSON(filepath.Join(f.state, request, "binding.json"), &rec.Binding)
		}
		rec.Control, e = pki.Issue(filepath.Join(f.state, "issuer"), pki.Identity{Owner: rec.Owner, Request: request, Attempt: "1", GuestUID: rec.GuestUID}, "control", 5*time.Minute)
		must(e)
		rec.Status = "Ready"
		f.save(rec)
		respond(w, 201, rec)
	case http.MethodGet:
		if rec == nil {
			http.Error(w, "request absent", 404)
			return
		}
		respond(w, 200, rec)
	default:
		http.Error(w, "method unsupported", 405)
	}
}
func (f *Foundation) action(w http.ResponseWriter, r *http.Request) {
	id, ok := f.principal(w, r)
	if !ok {
		return
	}
	request := r.PathValue("request")
	f.mu.Lock()
	defer f.mu.Unlock()
	rec := f.records[request]
	if rec == nil || id.Owner != rec.Owner || id.Request != request {
		http.Error(w, "owner or request denied", 403)
		return
	}
	if rec.Status != "Ready" {
		http.Error(w, "request not ready", 409)
		return
	}
	action := r.PathValue("action")
	if action != "inspect" && action != "finish" {
		http.Error(w, "unsupported capability", 422)
		return
	}
	if action == "inspect" && rec.Spec.Kind != "session" {
		http.Error(w, "session capability required", 422)
		return
	}
	operation := action
	if f.durable && action == "finish" {
		rec.Status = "CommandIntent"
		f.save(rec)
		operation = "execute"
	}
	if e := f.backend(operation, request, rec.Spec.Kind); e != nil {
		rec.Status = "CleanupPending"
		if stopErr := f.backend("stop", request, rec.Spec.Kind); stopErr == nil {
			rec.Status = "Failed"
			f.active = ""
		}
		http.Error(w, e.Error(), 500)
		return
	}
	if f.durable && action == "finish" {
		if _, err := os.Stat(filepath.Join(f.state, "crash-after-ack")); err == nil {
			os.Exit(77)
		}
		must(f.backend("stop", request, rec.Spec.Kind))
	}
	if action == "inspect" {
		b, e := os.ReadFile(filepath.Join(f.state, request, "inspect.txt"))
		must(e)
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write(b)
		return
	}
	completedAt := time.Now().UTC()
	var observations map[string]string
	readJSON(filepath.Join(f.state, request, "observed.json"), &observations)
	logs, e := os.ReadFile(filepath.Join(f.state, request, "output.log"))
	must(e)
	output, e := os.ReadFile(filepath.Join(f.state, request, "output.json"))
	must(e)
	rec.Expires = time.Now().UTC().Add(time.Minute)
	grant := evidence.Grant{GuestUID: rec.GuestUID, ExpiresAt: rec.Expires, SourceDigest: rec.Spec.SourceDigest, ToolDigest: f.config.ToolDigest, ProfileDigest: rec.Spec.ProfileDigest, Backend: rec.Backend}
	base := "/evidence/v1/owners/" + rec.Owner + "/requests/" + request + "/attempts/1"
	for _, item := range []struct {
		method, path string
		data         []byte
		want         int
	}{{"POST", base, mustMarshal(grant), 201}, {"POST", base + "/logs", logs, 204}, {"PUT", base + "/artifacts/output.json", output, 201}} {
		status, _, e := f.store(rec, item.method, item.path, item.data)
		if e != nil || status != item.want {
			panic(fmt.Sprintf("store %s status %d error %v", item.path, status, e))
		}
	}
	body := evidence.Receipt{Version: "konflux-sandbox.execution.v1", Owner: rec.Owner, Request: request, Attempt: 1, GuestUID: rec.GuestUID, SourceDigest: rec.Spec.SourceDigest, ToolDigest: f.config.ToolDigest, ProfileDigest: rec.Spec.ProfileDigest, Backend: rec.Backend, IssuedAt: time.Now().UTC(), CompletedAt: completedAt, RetainUntil: rec.Expires, Outcome: "Passed", Observed: observations, LogsDigest: evidence.Digest(logs), ArtifactDigests: map[string]string{"output.json": evidence.Digest(output)}}
	envelope, e := evidence.Sign(body, "supervisor", f.key)
	must(e)
	status, _, e := f.store(rec, "PUT", base+"/receipt", mustMarshal(envelope))
	if e != nil || status != 201 {
		panic(fmt.Sprintf("store receipt status %d error %v", status, e))
	}
	rec.Status = "Completed"
	f.save(rec)
	f.active = ""
	respond(w, 200, rec)
}
func mustMarshal(v any) []byte { b, e := json.Marshal(v); must(e); return b }
func (f *Foundation) store(rec *Record, method, path string, data []byte) (int, []byte, error) {
	c, e := pki.TLS(rec.Control.CA, rec.Control.Cert, rec.Control.Key)
	if e != nil {
		return 0, nil, e
	}
	c.ServerName = "gateway.prototype"
	req, e := http.NewRequest(method, "https://"+f.address+path, bytes.NewReader(data))
	if e != nil {
		return 0, nil, e
	}
	resp, e := (&http.Client{Transport: &http.Transport{TLSClientConfig: c}, Timeout: 10 * time.Second}).Do(req)
	if e != nil {
		return 0, nil, e
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(resp.Body)
	return resp.StatusCode, b, e
}
func (f *Foundation) evidence(w http.ResponseWriter, r *http.Request) {
	id, ok := f.principal(w, r)
	if !ok {
		return
	}
	f.mu.Lock()
	stored := f.records[r.PathValue("request")]
	var rec *Record
	if stored != nil {
		copy := *stored
		rec = &copy
	}
	f.mu.Unlock()
	if rec == nil || rec.Owner != id.Owner || rec.Request != id.Request {
		http.Error(w, "owner denied", 403)
		return
	}
	if rec.Status != "Completed" {
		http.Error(w, "not complete", 409)
		return
	}
	kind := r.PathValue("kind")
	if kind != "receipt" && kind != "logs" && kind != "output" {
		http.Error(w, "unsupported evidence", 422)
		return
	}
	suffix := kind
	if kind == "output" {
		suffix = "artifacts/output.json"
	}
	status, b, e := f.store(rec, "GET", "/evidence/v1/owners/"+rec.Owner+"/requests/"+rec.Request+"/attempts/1/"+suffix, nil)
	if e != nil {
		http.Error(w, e.Error(), 500)
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(b)
}
func main() {
	state := os.Args[1]
	f := &Foundation{state: state, records: map[string]*Record{}}
	_, durableErr := os.Stat(filepath.Join(state, "recovery-enabled"))
	f.durable = durableErr == nil
	readJSON(filepath.Join(state, "config.json"), &f.config)
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	must(e)
	f.pub, f.key = pub, key
	f.loadKey()
	pub = f.pub
	must(os.WriteFile(filepath.Join(state, "supervisor.pub"), pub, 0600))
	server, e := pki.Issue(filepath.Join(state, "issuer"), pki.Identity{Owner: "foundation", Request: "api", Attempt: "1", GuestUID: "host"}, "gateway", 5*time.Minute)
	must(e)
	c, e := pki.TLS(server.CA, server.Cert, server.Key)
	must(e)
	c.ClientAuth = tls.RequireAndVerifyClientCert
	mux := http.NewServeMux()
	mux.HandleFunc("GET /capabilities", func(w http.ResponseWriter, r *http.Request) {
		if _, ok := f.principal(w, r); ok {
			respond(w, 200, map[string]any{"config": f.config, "backends": []string{"finite", "session"}, "fullMemoryCheckpoint": false, "arbitraryTaskSpec": false, "supervisorKey": pub})
		}
	})
	mux.HandleFunc("/requests/{request}", f.request)
	mux.HandleFunc("POST /requests/{request}/{action}", f.action)
	mux.HandleFunc("GET /requests/{request}/evidence/{kind}", f.evidence)
	store := evidence.NewStore(map[string]ed25519.PublicKey{"supervisor": pub}, 2*time.Minute)
	mux.Handle("/evidence/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := pki.Parse(r.TLS.PeerCertificates[0], "control")
		if err != nil || id.GuestUID == "pending" {
			http.Error(w, "internal evidence identity required", 403)
			return
		}
		http.StripPrefix("/evidence", store.Handler()).ServeHTTP(w, r)
	}))
	go store.RunJanitor(context.Background())
	f.recover()
	var platform struct {
		HostIP string `json:"hostIP"`
	}
	readJSON(filepath.Join(state, "platform.json"), &platform)
	listener, e := net.Listen("tcp", net.JoinHostPort(platform.HostIP, "0"))
	must(e)
	f.address = listener.Addr().String()
	must(os.WriteFile(filepath.Join(state, "address"), []byte(f.address), 0600))
	must((&http.Server{Handler: mux, TLSConfig: c, ReadHeaderTimeout: 5 * time.Second}).ServeTLS(listener, "", ""))
}
