package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
	evidence "github.com/p5/konflux-sandbox/prototypes/private-evidence"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func require(ok bool, what string) {
	if !ok {
		panic(what)
	}
}
func encode(v any) []byte  { b, err := json.Marshal(v); must(err); return b }
func read(p string) []byte { b, err := os.ReadFile(p); must(err); return b }
func roots(ca string) *x509.CertPool {
	p := x509.NewCertPool()
	require(p.AppendCertsFromPEM(read(ca)), "invalid CA")
	return p
}
func client(ca, cert, key, name string) *http.Client {
	identity, err := tls.LoadX509KeyPair(cert, key)
	must(err)
	return &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots(ca), ServerName: name, Certificates: []tls.Certificate{identity}}}}
}
func serverTLS(ca, cert, key string) *tls.Config {
	identity, err := tls.LoadX509KeyPair(cert, key)
	must(err)
	return &tls.Config{MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: roots(ca), Certificates: []tls.Certificate{identity}}
}
func request(c *http.Client, method, url string, b []byte) (int, []byte) {
	r, err := http.NewRequest(method, url, bytes.NewReader(b))
	must(err)
	resp, err := c.Do(r)
	must(err)
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	must(err)
	return resp.StatusCode, out
}

func producer(c *http.Client, base string) {
	status, _ := request(c, "POST", base+"/logs", []byte("OWNER_A_PRIVATE_LOG_1\n"))
	require(status == 204, "first private log append")
	time.Sleep(150 * time.Millisecond)
	status, _ = request(c, "POST", base+"/logs", []byte("OWNER_A_PRIVATE_LOG_2\n"))
	require(status == 204, "second private log append")
	status, _ = request(c, "PUT", base+"/artifacts/reproducer", []byte("OWNER_A_PRIVATE_ARTIFACT"))
	require(status == 201, "private artifact upload")
}

func scenarios(state string) {
	must(os.MkdirAll(state, 0700))
	idA := pki.Identity{Owner: "owner-a", Request: "private-job", Attempt: "1", GuestUID: "local-producer-a"}
	idB := pki.Identity{Owner: "owner-b", Request: "private-job", Attempt: "1", GuestUID: "local-producer-b"}
	identityState, err := os.MkdirTemp(state, "identity-")
	must(err)
	defer os.RemoveAll(identityState)
	serverFiles, err := pki.Issue(identityState, pki.Identity{Owner: "operator", Request: "archive", Attempt: "1", GuestUID: "archive"}, "server", time.Minute)
	must(err)
	controlA, err := pki.Issue(identityState, idA, "control", time.Minute)
	must(err)
	controlB, err := pki.Issue(identityState, idB, "control", time.Minute)
	must(err)
	executionA, err := pki.Issue(identityState, idA, "execution", time.Minute)
	must(err)
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	_, guestKey, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	keys := map[string]ed25519.PublicKey{"supervisor-local-observer": pub}
	store := evidence.NewStore(keys, 10*time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go store.RunJanitor(ctx)
	server := httptest.NewUnstartedServer(store.Handler())
	server.TLS = serverTLS(serverFiles.CA, serverFiles.Cert, serverFiles.Key)
	server.Config.ErrorLog = evidence.QuietServerErrorLog()
	server.StartTLS()
	defer server.Close()
	a := client(controlA.CA, controlA.Cert, controlA.Key, serverFiles.ServerName)
	defer a.CloseIdleConnections()
	b := client(controlB.CA, controlB.Cert, controlB.Key, serverFiles.ServerName)
	defer b.CloseIdleConnections()
	guest := client(executionA.CA, executionA.Cert, executionA.Key, serverFiles.ServerName)
	defer guest.CloseIdleConnections()
	noCert := &http.Client{Timeout: time.Second, Transport: &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots(serverFiles.CA), ServerName: serverFiles.ServerName}}}
	_, err = noCert.Get(server.URL + "/v1/owners/owner-a/requests/private-job/attempts/1/metadata")
	require(err != nil, "missing client certificate accepted")
	noCert.CloseIdleConnections()
	base := server.URL + "/v1/owners/owner-a/requests/private-job/attempts/1"
	baseB := server.URL + "/v1/owners/owner-b/requests/private-job/attempts/1"
	expiry := time.Now().UTC().Add(4 * time.Second)
	grant := evidence.Grant{GuestUID: idA.GuestUID, ExpiresAt: expiry, SourceDigest: evidence.Digest([]byte("actual fixture source")), ToolDigest: evidence.Digest([]byte("local producer command")), ProfileDigest: evidence.Digest([]byte("local fixture; no VM isolation")), Backend: "local-producer-fixture"}
	status, _ := request(a, "POST", base, encode(grant))
	require(status == 201, "owner grant creation")
	status, _ = request(a, "POST", base, encode(grant))
	require(status == 200, "idempotent grant")
	otherGrant := grant
	otherGrant.GuestUID = idB.GuestUID
	status, _ = request(b, "POST", baseB, encode(otherGrant))
	require(status == 201, "second owner grant")
	status, _ = request(b, "POST", baseB+"/logs", []byte("OWNER_B_PRIVATE_LOG\n"))
	require(status == 204, "second owner private log")
	status, _ = request(b, "PUT", baseB+"/artifacts/private", []byte("OWNER_B_PRIVATE_ARTIFACT"))
	require(status == 201, "second owner private artifact")
	status, bPrivate := request(b, "GET", baseB+"/artifacts/private", nil)
	require(status == 200 && string(bPrivate) == "OWNER_B_PRIVATE_ARTIFACT", "second owner cannot retrieve its artifact")
	status, _ = request(a, "GET", baseB+"/logs", nil)
	require(status == 403, "reverse cross-owner read accepted")
	for _, suffix := range []string{"/metadata", "/logs", "/artifacts/reproducer", "/receipt"} {
		status, _ = request(b, "GET", base+suffix, nil)
		require(status == 403, "cross-owner read accepted")
	}
	status, _ = request(b, "POST", base+"/logs", []byte("cross-owner"))
	require(status == 403, "cross-owner write accepted")
	status, _ = request(guest, "GET", base+"/logs", nil)
	require(status == 403, "execution identity read archive")
	status, _ = request(a, "GET", server.URL+"/v1/owners/owner-a/requests/private-job/attempts/2/logs", nil)
	require(status == 403, "wrong attempt accepted")
	stream, err := a.Get(base + "/logs?follow=true")
	must(err)
	require(stream.StatusCode == 200, "private stream open")
	executable, err := os.Executable()
	must(err)
	child := exec.Command(executable, "-produce", "-url", base, "-ca", executionA.CA, "-cert", executionA.Cert, "-key", executionA.Key, "-server-name", serverFiles.ServerName)
	must(child.Start())
	reader := bufio.NewReader(stream.Body)
	line, err := reader.ReadString('\n')
	must(err)
	require(line == "OWNER_A_PRIVATE_LOG_1\n", "private first chunk")
	must(child.Wait())
	status, artifact := request(a, "GET", base+"/artifacts/reproducer", nil)
	require(status == 200 && string(artifact) == "OWNER_A_PRIVATE_ARTIFACT", "artifact after producer removal")
	status, _ = request(a, "PUT", base+"/artifacts/reproducer", []byte("overwrite"))
	require(status == 409, "artifact overwritten")
	status, logBytes := request(a, "GET", base+"/logs", nil)
	require(status == 200 && string(logBytes) == "OWNER_A_PRIVATE_LOG_1\nOWNER_A_PRIVATE_LOG_2\n", "logs after producer removal")
	status, metaBytes := request(a, "GET", base+"/metadata", nil)
	require(status == 200, "metadata read")
	var meta evidence.Metadata
	must(json.Unmarshal(metaBytes, &meta))
	now := time.Now().UTC()
	body := evidence.Receipt{Version: "konflux-sandbox.execution.v1", Owner: idA.Owner, Request: idA.Request, Attempt: 1, GuestUID: idA.GuestUID, SourceDigest: grant.SourceDigest, ToolDigest: grant.ToolDigest, ProfileDigest: grant.ProfileDigest, Backend: grant.Backend, IssuedAt: now, CompletedAt: now, RetainUntil: expiry, Outcome: "Passed", Observed: map[string]string{"pod_uid": idA.GuestUID, "producer_pid": strconv.Itoa(child.Process.Pid), "producer_removed": "true", "client_uri": executionA.URI, "scope": "local process fixture; no VM enforcement claim"}, LogsDigest: meta.LogsDigest, ArtifactDigests: meta.ArtifactDigests}
	valid, err := evidence.Sign(body, "supervisor-local-observer", key)
	must(err)
	for _, tc := range []struct {
		Name     string
		Envelope evidence.Envelope
	}{
		{"guest-authority", func() evidence.Envelope { e, err := evidence.Sign(body, "guest", guestKey); must(err); return e }()},
		{"wrong-source", func() evidence.Envelope {
			wrong := body
			wrong.SourceDigest = evidence.Digest([]byte("wrong"))
			e, err := evidence.Sign(wrong, "supervisor-local-observer", key)
			must(err)
			return e
		}()},
		{"wrong-content", func() evidence.Envelope {
			wrong := body
			wrong.LogsDigest = evidence.Digest([]byte("wrong"))
			e, err := evidence.Sign(wrong, "supervisor-local-observer", key)
			must(err)
			return e
		}()},
		{"tampered", func() evidence.Envelope { e := valid; e.Payload = append(bytes.Clone(e.Payload), ' '); return e }()},
	} {
		status, _ = request(a, "PUT", base+"/receipt", encode(tc.Envelope))
		require(status == 422, "invalid receipt accepted: "+tc.Name)
	}
	status, _ = request(guest, "PUT", base+"/receipt", encode(valid))
	require(status == 403, "guest submitted trusted receipt")
	status, _ = request(a, "PUT", base+"/receipt", encode(valid))
	require(status == 201, "independent supervisor receipt rejected")
	rest, err := io.ReadAll(reader)
	must(err)
	must(stream.Body.Close())
	require(string(rest) == "OWNER_A_PRIVATE_LOG_2\n" && stream.Trailer.Get("X-Evidence-Stream-State") == "sealed", "private stream completion")
	status, receiptBytes := request(a, "GET", base+"/receipt", nil)
	require(status == 200, "receipt after producer removal")
	var received evidence.Envelope
	must(json.Unmarshal(receiptBytes, &received))
	verified, err := evidence.Verify(received, keys)
	must(err)
	require(verified.Owner == idA.Owner && verified.LogsDigest == evidence.Digest(logBytes), "retrieved receipt binding")
	status, _ = request(a, "POST", base+"/logs", []byte("late"))
	require(status == 409, "sealed evidence changed")
	before := store.Bytes()
	require(before > 0, "private bytes missing before expiry")
	time.Sleep(time.Until(expiry.Add(80 * time.Millisecond)))
	for _, suffix := range []string{"/metadata", "/logs", "/artifacts/reproducer", "/receipt"} {
		status, _ = request(a, "GET", base+suffix, nil)
		require(status == 410, "retention did not revoke retrieval")
	}
	status, _ = request(a, "POST", base+"/logs", []byte("recreate"))
	require(status == 410, "expired request recreated")
	renewed := grant
	renewed.ExpiresAt = time.Now().UTC().Add(4 * time.Second)
	status, _ = request(a, "POST", base, encode(renewed))
	require(status == 410, "expired grant revived")
	require(store.Bytes() == 0, "expired private bytes remain in store")
	result := map[string]any{"mTLS_owner_identities": true, "missing_client_certificate_denied": true, "cross_owner_reads_and_writes_denied": true, "attempt_scope_enforced": true, "execution_identity_is_write_only": true, "private_log_chunk_observed_before_producer_exit": true, "logs_and_artifacts_available_after_producer_exit": true, "supervisor_signature_and_content_binding_verified": true, "guest_and_tampered_receipts_denied": true, "absolute_retention_expiry": expiry, "private_bytes_before_expiry": before, "private_bytes_after_expiry": store.Bytes(), "expired_reads_and_recreation_denied": true, "scope": "actual local producer process and mTLS; real guest/namespace removal belongs to foundation composition", "store": "in-memory host fixture; no crash recovery or forensic erasure claim"}
	fmt.Println(string(encode(result)))
}

func main() {
	serve := flag.Bool("serve", false, "Serve private evidence over mTLS")
	produce := flag.Bool("produce", false, "Run the short-lived private fixture producer")
	state := flag.String("state", ".prototype-state/private-evidence", "Ignored fixture state")
	url := flag.String("url", "", "Producer scope URL")
	ca := flag.String("ca", "", "Trusted client CA")
	cert := flag.String("cert", "", "TLS certificate")
	key := flag.String("key", "", "TLS private key")
	serverName := flag.String("server-name", "", "Expected server DNS name")
	listen := flag.String("listen", "127.0.0.1:0", "Listen address")
	pubFile := flag.String("supervisor-key", "", "Base64 Ed25519 supervisor public key file")
	issuer := flag.String("issuer", "supervisor", "Trusted supervisor issuer")
	ready := flag.String("ready-file", "", "Ignored ready file")
	maxRetention := flag.Duration("max-retention", 5*time.Minute, "Maximum evidence retention")
	flag.Parse()
	if *produce {
		c := client(*ca, *cert, *key, *serverName)
		defer c.CloseIdleConnections()
		producer(c, *url)
		return
	}
	if !*serve {
		scenarios(*state)
		return
	}
	pub, err := base64.StdEncoding.DecodeString(string(bytes.TrimSpace(read(*pubFile))))
	must(err)
	require(len(pub) == ed25519.PublicKeySize, "invalid supervisor public key")
	store := evidence.NewStore(map[string]ed25519.PublicKey{*issuer: ed25519.PublicKey(pub)}, *maxRetention)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go store.RunJanitor(ctx)
	listener, err := net.Listen("tcp", *listen)
	must(err)
	server := &http.Server{Handler: store.Handler(), TLSConfig: serverTLS(*ca, *cert, *key), ReadHeaderTimeout: 3 * time.Second, ErrorLog: evidence.QuietServerErrorLog()}
	if *ready != "" {
		must(os.WriteFile(*ready, encode(map[string]string{"url": "https://" + listener.Addr().String(), "server_name": *serverName}), 0600))
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	err = server.ServeTLS(listener, "", "")
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		panic(err)
	}
}
