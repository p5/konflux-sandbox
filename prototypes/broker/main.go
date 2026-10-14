package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const upstreamSecret = "PROTOTYPE-UPSTREAM-SECRET"

type grant struct {
	Execution string
	Target    string
	Deadline  time.Time
	Remaining int
	Revoked   bool
	Ctx       context.Context
	Cancel    context.CancelFunc
}

type broker struct {
	mu         sync.Mutex
	grants     map[string]*grant
	identities map[string]string
	client     *http.Client
}

func (b *broker) add(id, execution, target string, budget int, deadline time.Time) {
	ctx, cancel := context.WithCancel(context.Background())
	b.mu.Lock()
	defer b.mu.Unlock()
	b.grants[id] = &grant{Execution: execution, Target: target, Deadline: deadline, Remaining: budget, Ctx: ctx, Cancel: cancel}
}

func (b *broker) revoke(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.grants[id].Revoked = true
	b.grants[id].Cancel()
}

func (b *broker) infer(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Upstream") != "" {
		http.Error(w, "guest destination selection denied", http.StatusForbidden)
		return
	}
	b.mu.Lock()
	g := b.grants[r.PathValue("grant")]
	identity := b.identities[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
	if g == nil || identity == "" || identity != g.Execution {
		b.mu.Unlock()
		http.Error(w, "grant ownership denied", http.StatusForbidden)
		return
	}
	if g.Revoked || !time.Now().Before(g.Deadline) {
		b.mu.Unlock()
		http.Error(w, "grant expired or revoked", http.StatusGone)
		return
	}
	if g.Remaining <= 0 {
		b.mu.Unlock()
		http.Error(w, "grant budget exhausted", http.StatusTooManyRequests)
		return
	}
	g.Remaining--
	target, grantCtx, deadline := g.Target, g.Ctx, g.Deadline
	b.mu.Unlock()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024))
	if err != nil {
		http.Error(w, "body limit exceeded", http.StatusRequestEntityTooLarge)
		return
	}
	ctx, cancel := context.WithDeadline(r.Context(), deadline)
	defer cancel()
	stop := context.AfterFunc(grantCtx, cancel)
	defer stop()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target, strings.NewReader(string(body)))
	if err != nil {
		http.Error(w, "invalid configured destination", http.StatusBadGateway)
		return
	}
	request.Header.Set("Authorization", "Bearer "+upstreamSecret)
	response, err := b.client.Do(request)
	if err != nil {
		if grantCtx.Err() != nil {
			http.Error(w, "grant revoked during request", http.StatusGone)
		} else {
			http.Error(w, "upstream failed", http.StatusBadGateway)
		}
		return
	}
	defer response.Body.Close()
	if response.StatusCode >= 300 && response.StatusCode < 400 {
		http.Error(w, "upstream redirect denied", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(response.Body, 1024))
}

func require(ok bool, message string) {
	if !ok {
		fmt.Fprintln(os.Stderr, "FAIL:", message)
		os.Exit(1)
	}
}

func main() {
	var upstreamCalls, redirectCalls atomic.Int64
	entered := make(chan struct{}, 1)
	redirectTarget := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectCalls.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer redirectTarget.Close()
	upstreamMux := http.NewServeMux()
	upstreamMux.HandleFunc("POST /v1/infer", func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls.Add(1)
		if r.Header.Get("Authorization") != "Bearer "+upstreamSecret {
			http.Error(w, "upstream authentication missing", http.StatusUnauthorized)
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		_, _ = io.WriteString(w, `{"credentialAccepted":true,"secretReturned":false}`)
	})
	upstreamMux.HandleFunc("POST /redirect", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, redirectTarget.URL, http.StatusTemporaryRedirect)
	})
	upstreamMux.HandleFunc("POST /slow", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		entered <- struct{}{}
		<-r.Context().Done()
	})
	upstream := httptest.NewServer(upstreamMux)
	defer upstream.Close()
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	b := &broker{
		grants: map[string]*grant{}, identities: map[string]string{"guest-a": "execution-a", "guest-b": "execution-b"},
		client: &http.Client{Transport: transport, Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /grants/{grant}/infer", b.infer)
	proxy := httptest.NewServer(mux)
	defer proxy.Close()
	client := &http.Client{Transport: transport, Timeout: 4 * time.Second}
	deadline := time.Now().Add(30 * time.Second)
	b.add("allowed", "execution-a", upstream.URL+"/v1/infer", 1, deadline)
	b.add("redirect", "execution-a", upstream.URL+"/redirect", 1, deadline)
	b.add("expired", "execution-a", upstream.URL+"/v1/infer", 1, time.Now().Add(-time.Second))
	b.add("revoked", "execution-a", upstream.URL+"/v1/infer", 1, deadline)
	b.add("oversized", "execution-a", upstream.URL+"/v1/infer", 1, deadline)
	b.add("slow", "execution-a", upstream.URL+"/slow", 1, deadline)
	b.add("concurrent", "execution-a", upstream.URL+"/v1/infer", 1, deadline)
	b.revoke("revoked")
	request := func(method, id, token, body, override string) (int, string) {
		r, err := http.NewRequest(method, proxy.URL+"/grants/"+id+"/infer", strings.NewReader(body))
		require(err == nil, "construct request")
		r.Header.Set("Authorization", "Bearer "+token)
		if override != "" {
			r.Header.Set("X-Upstream", override)
		}
		response, err := client.Do(r)
		require(err == nil, "execute request")
		defer response.Body.Close()
		data, err := io.ReadAll(response.Body)
		require(err == nil, "read response")
		require(!strings.Contains(string(data), upstreamSecret), "upstream secret escaped in response")
		return response.StatusCode, string(data)
	}
	cases := []struct {
		Name, Method, Grant, Token, Body, Override string
		Expected                                   int
	}{
		{"cross-execution", "POST", "allowed", "guest-b", "{}", "", 403},
		{"guest-destination", "POST", "allowed", "guest-a", "{}", redirectTarget.URL, 403},
		{"method-scope", "GET", "allowed", "guest-a", "", "", 405},
		{"allowed-operation", "POST", "allowed", "guest-a", "{}", "", 200},
		{"budget-exhausted", "POST", "allowed", "guest-a", "{}", "", 429},
		{"redirect-blocked", "POST", "redirect", "guest-a", "{}", "", 502},
		{"expired", "POST", "expired", "guest-a", "{}", "", 410},
		{"revoked", "POST", "revoked", "guest-a", "{}", "", 410},
		{"oversized", "POST", "oversized", "guest-a", strings.Repeat("x", 1025), "", 413},
	}
	for _, c := range cases {
		status, _ := request(c.Method, c.Grant, c.Token, c.Body, c.Override)
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"case": c.Name, "expectedStatus": c.Expected, "observedStatus": status})
		require(status == c.Expected, c.Name)
	}
	result := make(chan int, 1)
	go func() {
		status, _ := request("POST", "slow", "guest-a", "{}", "")
		result <- status
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		require(false, "slow upstream did not start")
	}
	b.revoke("slow")
	status := <-result
	require(status == http.StatusGone, "revocation did not cancel in-flight upstream")
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"case": "in-flight-revocation", "observedStatus": status})
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Go(func() {
			status, _ := request("POST", "concurrent", "guest-a", "{}", "")
			statuses <- status
		})
	}
	wg.Wait()
	a, c := <-statuses, <-statuses
	require(a+c == http.StatusOK+http.StatusTooManyRequests && a != c, "concurrent requests exceeded grant budget")
	require(redirectCalls.Load() == 0, "redirect received a credential-bearing request")
	require(upstreamCalls.Load() == 2, "unexpected upstream operation count")
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"case": "concurrent-budget", "statuses": []int{a, c}, "redirectTargetCalls": redirectCalls.Load(), "upstreamCalls": upstreamCalls.Load()})
	fmt.Println("PASS broker HTTP scenarios; synthetic identities and secrets, no network isolation or Kubernetes identity proof.")
}
