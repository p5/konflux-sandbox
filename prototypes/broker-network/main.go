package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
)

type config struct {
	Identity      pki.Identity      `json:"identity"`
	ProfileDigest string            `json:"profileDigest"`
	Proxy         string            `json:"proxy"`
	Broker        string            `json:"broker"`
	ServerName    string            `json:"serverName"`
	Targets       map[string]string `json:"targets"`
	Allowed       []string          `json:"allowed"`
	Deadline      time.Time         `json:"deadline"`
	Budget        int               `json:"budget"`
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func decodeFile(path string, value any) {
	b, err := os.ReadFile(path)
	must(err)
	must(json.Unmarshal(b, value))
}
func tlsFiles(dir string) *tls.Config {
	c, err := pki.TLS(filepath.Join(dir, "ca.crt"), filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key"))
	must(err)
	return c
}
func audit(event string, data any) {
	b, _ := json.Marshal(map[string]any{"at": time.Now().UTC(), "event": event, "data": data})
	fmt.Println(string(b))
}

type operation struct {
	Target        string `json:"target"`
	Action        string `json:"action"`
	ProfileDigest string `json:"profileDigest"`
}

func broker(dir string) {
	var cfg config
	decodeFile(filepath.Join(dir, "config.json"), &cfg)
	secret, err := os.ReadFile(filepath.Join(dir, "upstream-secret"))
	must(err)
	proxy, err := url.Parse(cfg.Proxy)
	must(err)
	ca, err := os.ReadFile(filepath.Join(dir, "upstream-ca.crt"))
	must(err)
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		panic("upstream CA missing")
	}
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy), DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext, TLSHandshakeTimeout: 3 * time.Second, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}, DisableKeepAlives: true, ResponseHeaderTimeout: 4 * time.Second}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	var mu sync.Mutex
	revoked, remaining := false, cfg.Budget
	active := map[int]context.CancelFunc{}
	next := 0
	admin := http.NewServeMux()
	admin.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"revoked": revoked, "remaining": remaining, "active": len(active), "identity": cfg.Identity, "profileDigest": cfg.ProfileDigest})
	})
	admin.HandleFunc("POST /{action}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.PathValue("action") {
		case "revoke":
			revoked = true
			for _, cancel := range active {
				cancel()
			}
		case "restore":
			revoked = false
		default:
			http.Error(w, "unknown administration action", 400)
			return
		}
		audit("grant-"+r.PathValue("action"), cfg.Identity)
		w.WriteHeader(204)
	})
	go func() { must(http.ListenAndServe("127.0.0.1:9090", admin)) }()
	handler := http.NewServeMux()
	handler.HandleFunc("POST /operation", func(w http.ResponseWriter, r *http.Request) {
		id, err := pki.Parse(r.TLS.PeerCertificates[0], "execution")
		if err != nil || id != cfg.Identity || r.Header.Get("X-Grant") != "fixture-read" {
			http.Error(w, "execution or grant denied", 403)
			return
		}
		var op operation
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&op) != nil || op.Action != "read" || op.ProfileDigest != cfg.ProfileDigest || !slices.Contains(cfg.Allowed, op.Target) || cfg.Targets[op.Target] == "" {
			audit("grant-deny", map[string]any{"identity": id, "operation": op})
			http.Error(w, "operation destination or profile binding denied", 403)
			return
		}
		deadline := min(cfg.Deadline.UnixNano(), r.TLS.PeerCertificates[0].NotAfter.UnixNano(), time.Now().Add(8*time.Second).UnixNano())
		ctx, cancel := context.WithDeadline(r.Context(), time.Unix(0, deadline))
		defer cancel()
		mu.Lock()
		if revoked || !time.Now().Before(cfg.Deadline) {
			mu.Unlock()
			http.Error(w, "grant revoked or expired", 410)
			return
		}
		if remaining <= 0 {
			mu.Unlock()
			http.Error(w, "operation budget exhausted", 429)
			return
		}
		remaining--
		next++
		sequence := next
		active[sequence] = cancel
		mu.Unlock()
		defer func() { mu.Lock(); delete(active, sequence); mu.Unlock() }()
		upstream, err := http.NewRequestWithContext(ctx, http.MethodGet, cfg.Targets[op.Target], nil)
		must(err)
		upstream.Header.Set("Authorization", "Bearer "+string(secret))
		response, err := client.Do(upstream)
		if err != nil {
			audit("upstream-error", map[string]any{"identity": id, "target": op.Target, "error": err.Error()})
			http.Error(w, "upstream unavailable or cancelled", 502)
			return
		}
		defer response.Body.Close()
		if response.StatusCode >= 300 && response.StatusCode < 400 {
			audit("redirect-deny", map[string]any{"identity": id, "target": op.Target})
			http.Error(w, "upstream redirect denied", 502)
			return
		}
		audit("upstream-result", map[string]any{"identity": id, "target": op.Target, "status": response.StatusCode, "profileDigest": cfg.ProfileDigest})
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(response.StatusCode)
		buffer := make([]byte, 1024)
		for {
			n, err := response.Body.Read(buffer)
			if n > 0 {
				if _, writeErr := w.Write(buffer[:n]); writeErr != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
			if err != nil {
				return
			}
		}
	})
	c := tlsFiles(dir)
	c.ClientAuth = tls.RequireAndVerifyClientCert
	must((&http.Server{Addr: ":8443", Handler: handler, TLSConfig: c, ReadHeaderTimeout: 4 * time.Second}).ListenAndServeTLS("", ""))
}

func origin(dir string) {
	secret, err := os.ReadFile(filepath.Join(dir, "upstream-secret"))
	must(err)
	var mu sync.Mutex
	accepted, rejected := map[string]int{}, map[string]int{}
	cancelled := 0
	admin := http.NewServeMux()
	admin.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"accepted": accepted, "rejected": rejected, "cancelled": cancelled})
	})
	go func() { must(http.ListenAndServe("127.0.0.1:9091", admin)) }()
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		if r.Header.Get("Authorization") != "Bearer "+string(secret) {
			rejected[r.Host]++
			mu.Unlock()
			http.Error(w, "upstream credential absent", 401)
			return
		}
		accepted[r.Host]++
		mu.Unlock()
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "http://sink.test:8081/value", 302)
			return
		}
		if r.URL.Path == "/stream" {
			for n := 0; ; n++ {
				if _, err := fmt.Fprintf(w, "CHUNK-%d\n", n); err != nil {
					mu.Lock()
					cancelled++
					mu.Unlock()
					return
				}
				w.(http.Flusher).Flush()
				select {
				case <-r.Context().Done():
					mu.Lock()
					cancelled++
					mu.Unlock()
					return
				case <-time.After(100 * time.Millisecond):
				}
			}
		}
		fmt.Fprintln(w, "credential accepted at permitted local origin")
	})
	go func() {
		must(http.ListenAndServeTLS(":9444", filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key"), h))
	}()
	must(http.ListenAndServe(":8081", h))
}

func client(dir, target, action, profile string, want int, stream bool) {
	var cfg config
	decodeFile(filepath.Join(dir, "config.json"), &cfg)
	c := tlsFiles(dir)
	c.ServerName = cfg.ServerName
	proxy, err := url.Parse(cfg.Proxy)
	must(err)
	if profile != "" {
		cfg.ProfileDigest = profile
	}
	body, err := json.Marshal(operation{Target: target, Action: action, ProfileDigest: cfg.ProfileDigest})
	must(err)
	req, err := http.NewRequest(http.MethodPost, cfg.Broker+"/operation", strings.NewReader(string(body)))
	must(err)
	req.Header.Set("X-Grant", "fixture-read")
	httpClient := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: c, DisableKeepAlives: true}, Timeout: 12 * time.Second}
	response, err := httpClient.Do(req)
	if err != nil && want == 0 {
		fmt.Println("PASS guest gateway unavailable")
		return
	}
	must(err)
	defer response.Body.Close()
	if response.StatusCode != want {
		panic(fmt.Sprintf("target=%s status=%d want=%d", target, response.StatusCode, want))
	}
	if stream {
		start := time.Now()
		scanner := bufio.NewScanner(response.Body)
		chunks := 0
		for scanner.Scan() {
			chunks++
			fmt.Println(scanner.Text())
		}
		if chunks == 0 || time.Since(start) >= 10*time.Second || strings.Contains(fmt.Sprint(scanner.Err()), "deadline exceeded") {
			panic(fmt.Sprintf("stream did not close before client timeout: %v", scanner.Err()))
		}
		fmt.Println("PASS STREAM_CLOSED")
		return
	}
	b, err := io.ReadAll(io.LimitReader(response.Body, 8192))
	must(err)
	if want == 200 && !strings.Contains(string(b), "credential accepted") {
		panic("permitted origin did not confirm credential")
	}
	fmt.Printf("PASS target=%s status=%d body=%q\n", target, response.StatusCode, string(b))
}

func main() {
	mode := flag.String("mode", "", "issue, secret, origin, broker, or client")
	dir := flag.String("dir", "", "private fixture directory")
	owner := flag.String("owner", "alice", "certificate owner")
	request := flag.String("request", "broker-network", "certificate request")
	uid := flag.String("uid", "", "actual Pod UID")
	role := flag.String("role", "execution", "certificate role")
	target := flag.String("target", "allowed", "fixed operation alias")
	action := flag.String("action", "read", "requested operation")
	profile := flag.String("profile", "", "override requested profile identity")
	want := flag.Int("expect", 200, "expected response status")
	stream := flag.Bool("stream", false, "wait for active stream closure")
	flag.Parse()
	switch *mode {
	case "issue":
		files, err := pki.Issue(*dir, pki.Identity{Owner: *owner, Request: *request, Attempt: "1", GuestUID: *uid}, *role, 10*time.Minute)
		must(err)
		must(json.NewEncoder(os.Stdout).Encode(files))
	case "secret":
		must(os.WriteFile(*dir, []byte(rand.Text()), 0600))
	case "origin":
		origin(*dir)
	case "broker":
		broker(*dir)
	case "client":
		client(*dir, *target, *action, *profile, *want, *stream)
	default:
		panic("unknown fixture mode")
	}
}
