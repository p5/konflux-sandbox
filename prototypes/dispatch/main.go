package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const token = "PROTOTYPE-DISPATCH-IDENTITY"

type input struct {
	Script   string `json:"script"`
	Digest   string `json:"digest"`
	Deadline int    `json:"deadlineSeconds"`
}

type result struct {
	ID       string `json:"id"`
	Digest   string `json:"sourceDigest"`
	Outcome  string `json:"outcome"`
	Output   string `json:"output"`
	ExitCode int    `json:"exitCode"`
	Cleanup  bool   `json:"cleanupComplete"`
	Scope    string `json:"cleanupScope"`
}

type execution struct {
	Input  input
	Result result
	Cancel context.CancelFunc
}

type service struct {
	mu   sync.Mutex
	runs map[string]*execution
}

type outputBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *outputBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(data)
	if remaining := 4096 - b.b.Len(); remaining > 0 {
		_, _ = b.b.Write(data[:min(remaining, n)])
	}
	return n, nil
}

func digest(s string) string {
	d := sha256.Sum256([]byte(s))
	return "sha256:" + hex.EncodeToString(d[:])
}

func respond(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func (s *service) submit(w http.ResponseWriter, r *http.Request) {
	var in input
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&in); err != nil {
		http.Error(w, "invalid bounded input", 400)
		return
	}
	if in.Digest != digest(in.Script) || in.Deadline < 1 || in.Deadline > 10 {
		http.Error(w, "digest or deadline rejected", 400)
		return
	}
	id := r.PathValue("id")
	if len(id) == 0 || len(id) > 63 || strings.ContainsAny(id, "/. ") {
		http.Error(w, "invalid execution identifier", 400)
		return
	}
	s.mu.Lock()
	if existing := s.runs[id]; existing != nil {
		if existing.Input != in {
			s.mu.Unlock()
			http.Error(w, "request identity conflicts with prior input", 409)
			return
		}
		out := existing.Result
		s.mu.Unlock()
		respond(w, 200, out)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(in.Deadline)*time.Second)
	run := &execution{Input: in, Result: result{ID: id, Digest: in.Digest, Outcome: "Running", ExitCode: -1}, Cancel: cancel}
	s.runs[id] = run
	out := run.Result
	s.mu.Unlock()
	go s.execute(ctx, run)
	respond(w, 202, out)
}

func (s *service) execute(ctx context.Context, run *execution) {
	defer run.Cancel()
	dir, err := os.MkdirTemp("", "prototype-execution-")
	outcome, code := "InfrastructureFailure", -1
	var output outputBuffer
	if err == nil {
		script := filepath.Join(dir, "check.sh")
		err = os.WriteFile(script, []byte(run.Input.Script), 0600)
		if err == nil {
			cmd := exec.CommandContext(ctx, "/bin/sh", "-eu", script)
			cmd.Dir = dir
			cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir}
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
			cmd.WaitDelay = time.Second
			cmd.Stdout, cmd.Stderr = &output, &output
			err = cmd.Run()
			if cmd.Process != nil {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
			if err == nil {
				outcome, code = "Passed", 0
			} else if exit, ok := errors.AsType[*exec.ExitError](err); ok {
				outcome, code = "CheckFailed", exit.ExitCode()
			}
		}
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		outcome = "TimedOut"
	} else if ctx.Err() != nil {
		outcome = "Cancelled"
	}
	cleanup := dir == "" || os.RemoveAll(dir) == nil
	s.mu.Lock()
	run.Result.Outcome, run.Result.ExitCode = outcome, code
	run.Result.Output, run.Result.Cleanup = output.b.String(), cleanup
	run.Result.Scope = "process-group-and-files"
	s.mu.Unlock()
}

func (s *service) status(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	run := s.runs[r.PathValue("id")]
	if run == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method == http.MethodDelete {
		run.Cancel()
	}
	respond(w, 200, run.Result)
}

func serve() {
	s := &service{runs: map[string]*execution{}}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /executions/{id}", s.submit)
	mux.HandleFunc("GET /executions/{id}", s.status)
	mux.HandleFunc("DELETE /executions/{id}", s.status)
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" && r.Header.Get("Authorization") != "Bearer "+token {
			http.Error(w, "execution identity required", 403)
			return
		}
		mux.ServeHTTP(w, r)
	})
	server := &http.Server{Addr: ":8080", Handler: handler, ReadHeaderTimeout: 3 * time.Second}
	fmt.Println("PROTOTYPE executor: shared container process, no VM isolation or durable request store")
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func client(url string) {
	c := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer c.CloseIdleConnections()
	call := func(method, id string, in *input, authenticated bool) (int, result) {
		var body []byte
		if in != nil {
			body, _ = json.Marshal(in)
		}
		r, _ := http.NewRequest(method, url+"/executions/"+id, bytes.NewReader(body))
		if authenticated {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := c.Do(r)
		if err != nil {
			panic(err)
		}
		defer response.Body.Close()
		var out result
		_ = json.NewDecoder(response.Body).Decode(&out)
		return response.StatusCode, out
	}
	require := func(ok bool, what string) {
		if !ok {
			fmt.Fprintln(os.Stderr, "FAIL:", what)
			os.Exit(1)
		}
	}
	prefix := fmt.Sprintf("cli-%d-", time.Now().UnixNano())
	script := "printf 'actual remote command output\\n'\n"
	in := input{Script: script, Digest: digest(script), Deadline: 5}
	status, _ := call("POST", prefix+"pass", &in, false)
	require(status == 403, "missing identity accepted")
	status, _ = call("POST", prefix+"pass", &in, true)
	require(status == 202, "initial dispatch")
	status, _ = call("POST", prefix+"pass", &in, true)
	require(status == 200, "idempotent submission")
	changed := in
	changed.Script, changed.Digest = "exit 1\n", digest("exit 1\n")
	status, _ = call("POST", prefix+"pass", &changed, true)
	require(status == 409, "conflicting request identity accepted")
	bad := in
	bad.Digest = "sha256:wrong"
	status, _ = call("POST", prefix+"bad", &bad, true)
	require(status == 400, "incorrect source digest accepted")
	wait := func(id, expected string) result {
		deadline := time.Now().Add(12 * time.Second)
		for time.Now().Before(deadline) {
			_, out := call("GET", id, nil, true)
			if out.Cleanup {
				require(out.Outcome == expected, id+" outcome "+out.Outcome)
				_ = json.NewEncoder(os.Stdout).Encode(out)
				return out
			}
			time.Sleep(50 * time.Millisecond)
		}
		require(false, "execution did not complete with cleanup")
		return result{}
	}
	wait(prefix+"pass", "Passed")
	_, _ = call("POST", prefix+"fail", &changed, true)
	wait(prefix+"fail", "CheckFailed")
	slow := input{Script: "sleep 30\n", Digest: digest("sleep 30\n"), Deadline: 5}
	_, _ = call("POST", prefix+"cancel", &slow, true)
	_, _ = call("DELETE", prefix+"cancel", nil, true)
	wait(prefix+"cancel", "Cancelled")
	slow.Deadline = 1
	_, _ = call("POST", prefix+"timeout", &slow, true)
	wait(prefix+"timeout", "TimedOut")
	background := input{Script: "sleep 30 >/dev/null 2>&1 & echo background-child=$!\n", Deadline: 5}
	background.Digest = digest(background.Script)
	_, _ = call("POST", prefix+"background", &background, true)
	out := wait(prefix+"background", "Passed")
	pidText, found := strings.CutPrefix(strings.TrimSpace(out.Output), "background-child=")
	pid, err := strconv.Atoi(pidText)
	require(found && err == nil && pid > 0, "background process identity missing")
	check := input{Script: fmt.Sprintf("if [ -r /proc/%d/stat ]; then state=$(awk '{print $3}' /proc/%d/stat); [ \"$state\" = Z ]; fi\n", pid, pid), Deadline: 5}
	check.Digest = digest(check.Script)
	_, _ = call("POST", prefix+"background-stopped", &check, true)
	wait(prefix+"background-stopped", "Passed")
	fmt.Println("PASS remote dispatch scenarios; process/container execution only, identity is synthetic, persistence is absent.")
}

func main() {
	server := flag.Bool("serve", false, "Run the throwaway execution endpoint")
	url := flag.String("url", "http://127.0.0.1:8080", "Prototype endpoint")
	cancelID := flag.String("cancel", "", "Cancel one prototype execution")
	flag.Parse()
	if *server {
		serve()
	} else if *cancelID != "" {
		request, _ := http.NewRequest(http.MethodDelete, *url+"/executions/"+*cancelID, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		c := &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{Proxy: nil}}
		defer c.CloseIdleConnections()
		response, err := c.Do(request)
		if err != nil {
			panic(err)
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			os.Exit(1)
		}
	} else {
		client(*url)
	}
}
