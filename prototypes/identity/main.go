package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
	"golang.org/x/net/http2"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func readJSON(path string, v any) { b, e := os.ReadFile(path); must(e); must(json.Unmarshal(b, v)) }
func tlsFiles(prefix string) (*tls.Config, error) {
	return pki.TLS(prefix+"/ca.crt", prefix+"/tls.crt", prefix+"/tls.key")
}

func guest(dir string) {
	c, e := tlsFiles(dir)
	must(e)
	c.ClientAuth = tls.RequireAndVerifyClientCert
	var identity pki.Identity
	readJSON(filepath.Join(dir, "identity.json"), &identity)
	rest, _ := url.Parse("http://127.0.0.1:8080")
	grpc, _ := url.Parse("http://127.0.0.1:9090")
	rp := httputil.NewSingleHostReverseProxy(rest)
	gp := httputil.NewSingleHostReverseProxy(grpc)
	gp.Transport = &http2.Transport{AllowHTTP: true, DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		i, e := pki.Parse(r.TLS.PeerCertificates[0], "control")
		if e != nil || i != identity {
			http.Error(w, "control identity denied", 403)
			return
		}
		if strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc") {
			gp.ServeHTTP(w, r)
		} else {
			rp.ServeHTTP(w, r)
		}
	})
	s := &http.Server{Addr: ":8443", TLSConfig: c, Handler: h, ReadHeaderTimeout: 5 * time.Second}
	must(http2.ConfigureServer(s, &http2.Server{}))
	must(s.ListenAndServeTLS("", ""))
}

type Route struct {
	Identity   pki.Identity `json:"identity"`
	URL        string       `json:"url"`
	ServerName string       `json:"serverName"`
	TLSDir     string       `json:"tlsDir"`
}
type Routes struct {
	Active map[string]string `json:"active"`
	Routes map[string]Route  `json:"routes"`
}

func gateway(dir, listen string) {
	c, e := tlsFiles(dir)
	must(e)
	c.ClientAuth = tls.RequireAndVerifyClientCert
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		i, e := pki.Parse(r.TLS.PeerCertificates[0], "control")
		if e != nil {
			http.Error(w, "control identity denied", 403)
			return
		}
		var cfg Routes
		b, e := os.ReadFile(filepath.Join(dir, "routes.json"))
		if e != nil || json.Unmarshal(b, &cfg) != nil {
			http.Error(w, "routes unavailable", 503)
			return
		}
		uid := r.Header.Get("X-Guest-UID")
		route, ok := cfg.Routes[uid]
		if !ok || route.Identity != i || cfg.Active[binding(i)] != uid {
			http.Error(w, "guest binding denied", 403)
			return
		}
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(20 * time.Millisecond):
					var current Routes
					b, e := os.ReadFile(filepath.Join(dir, "routes.json"))
					if e != nil || json.Unmarshal(b, &current) != nil || current.Active[binding(i)] != uid || !time.Now().Before(r.TLS.PeerCertificates[0].NotAfter) {
						cancel()
						return
					}
				}
			}
		}()
		out, e := tlsFiles(route.TLSDir)
		if e != nil {
			http.Error(w, "route identity unavailable", 503)
			return
		}
		out.ServerName = route.ServerName
		out.VerifyConnection = func(s tls.ConnectionState) error {
			peer, e := pki.Parse(s.PeerCertificates[0], "server")
			if e != nil {
				return e
			}
			if peer != route.Identity {
				return fmt.Errorf("wrong destination identity")
			}
			return nil
		}
		u, e := url.Parse(route.URL)
		if e != nil {
			http.Error(w, "bad route", 503)
			return
		}
		proxy := httputil.NewSingleHostReverseProxy(u)
		proxy.Transport = &http.Transport{TLSClientConfig: out, ForceAttemptHTTP2: true, DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext, TLSHandshakeTimeout: 2 * time.Second}
		proxy.FlushInterval = -1
		proxy.ServeHTTP(w, r.WithContext(ctx))
	})
	l, e := net.Listen("tcp", listen)
	must(e)
	must(os.WriteFile(filepath.Join(dir, "address"), []byte(l.Addr().String()), 0600))
	s := &http.Server{Handler: h, TLSConfig: c, ReadHeaderTimeout: 5 * time.Second}
	must(http2.ConfigureServer(s, &http2.Server{}))
	must(s.ServeTLS(l, "", ""))
}

type Grant struct {
	Identity pki.Identity `json:"identity"`
	Expires  time.Time    `json:"expires"`
	Revoked  bool         `json:"revoked"`
	Action   string       `json:"action"`
}
type Config struct {
	Active map[string]string `json:"active"`
	Grants map[string]Grant  `json:"grants"`
}

func binding(i pki.Identity) string { return i.Owner + "/" + i.Request + "/" + i.Attempt }
func authorized(file, grantID string, i pki.Identity) bool {
	var cfg Config
	b, e := os.ReadFile(file)
	if e != nil || json.Unmarshal(b, &cfg) != nil {
		return false
	}
	g, ok := cfg.Grants[grantID]
	return ok && !g.Revoked && g.Identity == i && g.Action == "read-fixture" && time.Now().Before(g.Expires) && cfg.Active[binding(i)] == i.GuestUID
}

func broker(dir, listen string) {
	secret := rand.Text()
	must(os.WriteFile(filepath.Join(dir, "upstream-secret"), []byte(secret), 0600))
	var mu sync.Mutex
	requests := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+secret {
			http.Error(w, "missing upstream credential", 401)
			return
		}
		mu.Lock()
		requests++
		must(os.WriteFile(filepath.Join(dir, "upstream-count"), []byte(strconv.Itoa(requests)), 0600))
		mu.Unlock()
		if r.URL.Query().Get("stream") == "true" {
			w.Header().Set("Content-Type", "text/plain")
			for n := range 200 {
				select {
				case <-r.Context().Done():
					must(os.WriteFile(filepath.Join(dir, "upstream-cancelled"), []byte("cancelled"), 0600))
					return
				case <-time.After(25 * time.Millisecond):
					fmt.Fprintf(w, "chunk-%d\n", n)
					w.(http.Flusher).Flush()
				}
			}
			return
		}
		fmt.Fprint(w, "fixture-result; upstream-secret-injected")
	}))
	defer upstream.Close()
	c, e := tlsFiles(dir)
	must(e)
	c.ClientAuth = tls.RequireAndVerifyClientCert
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/operation" || r.Method != http.MethodGet {
			http.Error(w, "operation denied", 403)
			return
		}
		i, e := pki.Parse(r.TLS.PeerCertificates[0], "execution")
		gid := r.Header.Get("X-Grant")
		if e != nil || !authorized(filepath.Join(dir, "grants.json"), gid, i) {
			http.Error(w, "identity or grant denied", 403)
			return
		}
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(20 * time.Millisecond):
					if !authorized(filepath.Join(dir, "grants.json"), gid, i) || !time.Now().Before(r.TLS.PeerCertificates[0].NotAfter) {
						cancel()
						return
					}
				}
			}
		}()
		req, e := http.NewRequestWithContext(ctx, http.MethodGet, upstream.URL+"/?"+r.URL.RawQuery, nil)
		if e != nil {
			http.Error(w, "request failed", 500)
			return
		}
		req.Header.Set("Authorization", "Bearer "+secret)
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			http.Error(w, "upstream cancelled", 502)
			return
		}
		defer resp.Body.Close()
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(resp.StatusCode)
		buf := make([]byte, 256)
		for {
			n, e := resp.Body.Read(buf)
			if n > 0 {
				_, _ = w.Write(buf[:n])
				w.(http.Flusher).Flush()
			}
			if e != nil {
				return
			}
		}
	})
	l, e := net.Listen("tcp", listen)
	must(e)
	must(os.WriteFile(filepath.Join(dir, "address"), []byte(l.Addr().String()), 0600))
	s := &http.Server{Handler: h, TLSConfig: c, ReadHeaderTimeout: 5 * time.Second}
	must(http2.ConfigureServer(s, &http2.Server{}))
	must(s.ServeTLS(l, "", ""))
}

func client(args []string) {
	if len(args) != 6 {
		panic("client DIR SERVER_NAME URL GRANT EXPECTED_STATUS OUTPUT")
	}
	c, e := tlsFiles(args[0])
	must(e)
	c.ServerName = args[1]
	req, e := http.NewRequest(http.MethodGet, args[2], nil)
	must(e)
	req.Header.Set("X-Grant", args[3])
	resp, e := (&http.Client{Transport: &http.Transport{TLSClientConfig: c}, Timeout: 15 * time.Second}).Do(req)
	if args[4] == "tls-denied" {
		if e == nil {
			resp.Body.Close()
			panic("TLS unexpectedly accepted")
		}
		if !strings.Contains(e.Error(), "expired") {
			panic(fmt.Sprintf("expected expired certificate rejection, got %v", e))
		}
		fmt.Println("PASS TLS identity rejected")
		return
	}
	must(e)
	defer resp.Body.Close()
	want, e := strconv.Atoi(args[4])
	must(e)
	if resp.StatusCode != want {
		panic(fmt.Sprintf("status %d, expected %d", resp.StatusCode, want))
	}
	f, e := os.Create(args[5])
	must(e)
	_, e = io.Copy(f, resp.Body)
	must(e)
	must(f.Close())
	fmt.Printf("PASS mTLS status %d\n", want)
}

func main() {
	if len(os.Args) < 2 {
		panic("issue|guest|broker|client")
	}
	switch os.Args[1] {
	case "issue":
		if len(os.Args) != 9 {
			panic("issue STATE OWNER REQUEST ATTEMPT GUEST_UID ROLE SECONDS")
		}
		seconds, e := strconv.Atoi(os.Args[8])
		must(e)
		f, e := pki.Issue(os.Args[2], pki.Identity{Owner: os.Args[3], Request: os.Args[4], Attempt: os.Args[5], GuestUID: os.Args[6]}, os.Args[7], time.Duration(seconds)*time.Second)
		must(e)
		must(json.NewEncoder(os.Stdout).Encode(f))
	case "guest":
		guest(os.Args[2])
	case "broker":
		broker(os.Args[2], os.Args[3])
	case "gateway":
		gateway(os.Args[2], os.Args[3])
	case "client":
		client(os.Args[2:])
	default:
		panic("unknown mode")
	}
}
