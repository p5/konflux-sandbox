package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

type policy struct {
	Execution          string   `json:"execution"`
	Revision           string   `json:"revision"`
	Domains            []string `json:"domains"`
	IPs                []string `json:"ips"`
	ResolvedPrivateIPs []string `json:"resolvedPrivateIPs"`
	DomainPorts        []int    `json:"domainPorts"`
	IPPorts            []int    `json:"ipPorts"`
	Protected          []string `json:"protected"`
	DNS                string   `json:"dns"`
	IPv6               bool     `json:"ipv6"`
	Protocols          []string `json:"protocols"`
	OpaqueDomains      bool     `json:"opaqueDomains"`
}

func loadPolicy(file string) (policy, error) {
	var p policy
	f, err := os.Open(file)
	if err != nil {
		return p, err
	}
	defer f.Close()
	decoder := json.NewDecoder(f)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&p); err != nil {
		return p, err
	}
	if p.IPv6 || p.OpaqueDomains || len(p.Protocols) != 1 || p.Protocols[0] != "tcp" {
		return p, errors.New("unsupported profile: IPv4 TCP with inspected HTTP/S domains only")
	}
	return p, nil
}

type gateway struct {
	policy      policy
	ca          *x509.Certificate
	key         *ecdsa.PrivateKey
	roots       *x509.CertPool
	mu          sync.Mutex
	ready       bool
	revoked     bool
	connections map[net.Conn]bool
	resolver    *net.Resolver
}

var denied = errors.New("destination denied")

func (g *gateway) audit(action, destination, reason string) {
	b, _ := json.Marshal(map[string]any{"timestamp": time.Now().UTC(), "execution": g.policy.Execution, "revision": g.policy.Revision, "action": action, "destination": destination, "reason": reason})
	fmt.Println(string(b))
}

func normalizedHost(host string) (string, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if net.ParseIP(host) != nil {
		return host, nil
	}
	if host == "" || len(host) > 253 {
		return "", denied
	}
	for label := range strings.SplitSeq(host, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "", denied
		}
		for _, c := range label {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
				return "", denied
			}
		}
	}
	return host, nil
}

func (g *gateway) available() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.ready && !g.revoked
}

func inPrefixes(host string, prefixes []string) bool {
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	for _, value := range prefixes {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			if value == addr.String() {
				return true
			}
			continue
		}
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func (g *gateway) authorize(host string, port int, domain bool) error {
	if !g.available() {
		return fmt.Errorf("%w: enforcement unavailable or revoked", denied)
	}
	if inPrefixes(host, g.policy.Protected) {
		return fmt.Errorf("%w: protected destination", denied)
	}
	if net.ParseIP(host) != nil {
		if !domain && slices.Contains(g.policy.IPPorts, port) && inPrefixes(host, g.policy.IPs) {
			return nil
		}
		return fmt.Errorf("%w: IP or port outside explicit grant", denied)
	}
	if !domain || !slices.Contains(g.policy.DomainPorts, port) {
		return fmt.Errorf("%w: unsupported domain protocol or port", denied)
	}
	for _, pattern := range g.policy.Domains {
		if host == pattern || (strings.HasPrefix(pattern, "*.") && strings.HasSuffix(host, pattern[1:]) && host != pattern[2:] && !strings.Contains(strings.TrimSuffix(host, pattern[1:]), ".")) {
			return nil
		}
	}
	return fmt.Errorf("%w: hostname outside allowlist", denied)
}

func (g *gateway) dial(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	var addresses []string
	if net.ParseIP(host) != nil {
		addresses = []string{host}
	} else {
		addresses, err = g.resolver.LookupHost(ctx, host)
		if err != nil {
			return nil, err
		}
	}
	if len(addresses) == 0 {
		return nil, errors.New("DNS returned no addresses")
	}
	for _, address := range addresses {
		ip := net.ParseIP(address)
		if ip.To4() == nil || ip.IsMulticast() || ip.IsUnspecified() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || inPrefixes(address, g.policy.Protected) || (ip.IsPrivate() && !inPrefixes(address, append(slices.Clone(g.policy.ResolvedPrivateIPs), g.policy.IPs...))) {
			return nil, fmt.Errorf("%w: DNS resolved protected or unsupported address", denied)
		}
	}
	if !g.available() {
		return nil, denied
	}
	g.audit("dial", net.JoinHostPort(host, port), strings.Join(addresses, ","))
	return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "tcp4", net.JoinHostPort(addresses[0], port))
}

func destination(u *url.URL) (string, int, error) {
	host, err := normalizedHost(u.Hostname())
	if err != nil || u.User != nil {
		return "", 0, denied
	}
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return "", 0, denied
	}
	return host, n, nil
}

func (g *gateway) forward(req *http.Request) (*http.Response, error) {
	if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
		return nil, denied
	}
	host, port, err := destination(req.URL)
	if err != nil {
		return nil, err
	}
	if err := g.authorize(host, port, net.ParseIP(host) == nil); err != nil {
		return nil, err
	}
	if req.Host != "" && !strings.EqualFold(strings.TrimSuffix(req.Host, "."), req.URL.Host) {
		return nil, fmt.Errorf("%w: HTTP Host differs from URL", denied)
	}
	copy := req.Clone(req.Context())
	copy.RequestURI = ""
	copy.Header.Del("Proxy-Authorization")
	copy.Header.Del("Proxy-Connection")
	copy.Header.Del("Connection")
	transport := &http.Transport{DialContext: g.dial, DisableKeepAlives: true, TLSClientConfig: &tls.Config{RootCAs: g.roots, MinVersion: tls.VersionTLS13}, ResponseHeaderTimeout: 4 * time.Second}
	return transport.RoundTrip(copy)
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.Method == http.MethodConnect {
		g.connect(w, req)
		return
	}
	resp, err := g.forward(req)
	if err != nil {
		g.audit("deny", req.URL.String(), err.Error())
		status := http.StatusBadGateway
		if errors.Is(err, denied) {
			status = http.StatusForbidden
		}
		http.Error(w, err.Error(), status)
		return
	}
	defer resp.Body.Close()
	g.audit("allow", req.URL.String(), "inspected HTTP")
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				return
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

func (g *gateway) forget(conn net.Conn) {
	g.mu.Lock()
	delete(g.connections, conn)
	g.mu.Unlock()
	conn.Close()
}

func (g *gateway) connect(w http.ResponseWriter, req *http.Request) {
	host, rawPort, err := net.SplitHostPort(req.Host)
	if err != nil {
		http.Error(w, "CONNECT needs host:port", 400)
		return
	}
	host, err = normalizedHost(host)
	port, portErr := strconv.Atoi(rawPort)
	domain := net.ParseIP(host) == nil
	if err != nil || portErr != nil {
		http.Error(w, "invalid CONNECT destination", 400)
		return
	}
	if err := g.authorize(host, port, domain); err != nil {
		g.audit("deny", req.Host, err.Error())
		http.Error(w, err.Error(), 403)
		return
	}
	var upstream net.Conn
	if !domain {
		upstream, err = g.dial(req.Context(), "tcp", req.Host)
		if err != nil {
			http.Error(w, err.Error(), 403)
			return
		}
		defer upstream.Close()
	}
	conn, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer g.forget(conn)
	fmt.Fprint(buffered, "HTTP/1.1 200 Connection Established\r\n\r\n")
	buffered.Flush()
	if !domain {
		g.audit("allow", req.Host, "opaque TCP via explicit IP and port")
		done := make(chan struct{})
		go func() { io.Copy(upstream, buffered); upstream.Close(); close(done) }()
		io.Copy(conn, upstream)
		conn.Close()
		<-done
		return
	}
	cert, err := issueServer(g.ca, g.key, []string{host})
	if err != nil {
		return
	}
	secure := tls.Server(conn, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13, NextProtos: []string{"http/1.1"}, GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
		name, err := normalizedHost(hello.ServerName)
		if err != nil || name != host {
			g.audit("deny", hello.ServerName, "SNI differs from CONNECT name")
			return nil, denied
		}
		return nil, nil
	}})
	if err := secure.Handshake(); err != nil {
		return
	}
	reader := bufio.NewReader(secure)
	for {
		inner, err := http.ReadRequest(reader)
		if err != nil {
			return
		}
		if inner.Host != req.Host {
			g.audit("deny", inner.Host, "HTTPS Host differs from CONNECT name")
			fmt.Fprint(secure, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			return
		}
		inner.URL.Scheme = "https"
		inner.URL.Host = req.Host
		inner = inner.WithContext(req.Context())
		resp, err := g.forward(inner)
		if err != nil {
			g.audit("deny", inner.Host, err.Error())
			fmt.Fprint(secure, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
			return
		}
		g.audit("allow", inner.URL.String(), "TLS terminated; SNI and HTTP Host checked; upstream certificate verified")
		writeErr := resp.Write(secure)
		resp.Body.Close()
		if writeErr != nil || inner.Close {
			return
		}
	}
}

func serveGateway(file, dir string) error {
	p, err := loadPolicy(file)
	if err != nil {
		return err
	}
	g := &gateway{connections: map[net.Conn]bool{}, ready: true}
	g.policy = p
	if podIP := os.Getenv("POD_IP"); podIP != "" {
		g.policy.Protected = append(g.policy.Protected, podIP+"/32")
	}
	for _, value := range []string{"127.0.0.0/8", "169.254.0.0/16", "0.0.0.0/8", "::/0"} {
		g.policy.Protected = append(g.policy.Protected, value)
	}
	b, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return errors.New("missing CA certificate")
	}
	g.ca, err = x509.ParseCertificate(block.Bytes)
	if err != nil {
		return err
	}
	g.roots = x509.NewCertPool()
	g.roots.AppendCertsFromPEM(b)
	b, err = os.ReadFile(filepath.Join(dir, "ca.key"))
	if err != nil {
		return err
	}
	block, _ = pem.Decode(b)
	if block == nil {
		return errors.New("missing CA key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return err
	}
	g.key = key.(*ecdsa.PrivateKey)
	g.resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "udp", g.policy.DNS)
	}}
	admin := http.NewServeMux()
	admin.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		defer g.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"ready": g.ready, "revoked": g.revoked, "execution": g.policy.Execution, "revision": g.policy.Revision})
	})
	admin.HandleFunc("POST /{action}", func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		switch r.PathValue("action") {
		case "revoke":
			g.revoked = true
		case "fail":
			g.ready = false
		case "restore":
			g.ready = true
			g.revoked = false
		default:
			g.mu.Unlock()
			http.Error(w, "unknown action", 400)
			return
		}
		var active []net.Conn
		if !g.ready || g.revoked {
			for c := range g.connections {
				active = append(active, c)
			}
		}
		g.mu.Unlock()
		for _, c := range active {
			c.Close()
		}
		g.audit(r.PathValue("action"), "all active flows", "trusted loopback administration")
		w.WriteHeader(204)
	})
	go func() {
		if err := http.ListenAndServe("127.0.0.1:9090", admin); err != nil {
			panic(err)
		}
	}()
	server := &http.Server{Addr: ":8080", Handler: g, ReadHeaderTimeout: 5 * time.Second, ConnState: func(c net.Conn, state http.ConnState) {
		g.mu.Lock()
		defer g.mu.Unlock()
		if state == http.StateNew {
			g.connections[c] = true
		}
		if state == http.StateClosed {
			delete(g.connections, c)
		}
	}}
	return server.ListenAndServe()
}
