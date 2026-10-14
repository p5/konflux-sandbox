package client

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
	evidence "github.com/p5/konflux-sandbox/prototypes/private-evidence"
)

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func Run(mode string, args []string) {
	dir, address, request := args[0], args[1], args[2]
	leaf, e := os.ReadFile(dir + "/tls.crt")
	must(e)
	block, _ := pem.Decode(leaf)
	cert, e := x509.ParseCertificate(block.Bytes)
	must(e)
	id, e := pki.Parse(cert, "control")
	must(e)
	c, e := pki.TLS(dir+"/ca.crt", dir+"/tls.crt", dir+"/tls.key")
	must(e)
	c.ServerName = "gateway.prototype"
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: c}, Timeout: 180 * time.Second}
	call := func(method, path string, value any, want int) []byte {
		var b []byte
		if value != nil {
			b, e = json.Marshal(value)
			must(e)
		}
		req, e := http.NewRequest(method, "https://"+address+path, bytes.NewReader(b))
		must(e)
		resp, e := client.Do(req)
		must(e)
		defer resp.Body.Close()
		b, e = io.ReadAll(resp.Body)
		must(e)
		if resp.StatusCode != want {
			panic(fmt.Sprintf("%s status %d expected %d: %s", path, resp.StatusCode, want, b))
		}
		return b
	}
	path := "/requests/" + request
	if mode == "cross-owner" {
		call("GET", path, nil, 403)
		fmt.Println("PASS cross-owner consumer denied")
		return
	}
	if mode == "expired" {
		for range 900 {
			req, e := http.NewRequest("GET", "https://"+address+path+"/evidence/receipt", nil)
			must(e)
			resp, e := client.Do(req)
			must(e)
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 410 {
				fmt.Println("PASS evidence retention expired after workload deletion")
				return
			}
			if resp.StatusCode != 200 {
				panic("unexpected expiry status")
			}
			time.Sleep(100 * time.Millisecond)
		}
		panic("evidence did not expire")
	}
	var caps struct {
		Config               map[string]string `json:"config"`
		SupervisorKey        []byte            `json:"supervisorKey"`
		FullMemoryCheckpoint bool              `json:"fullMemoryCheckpoint"`
	}
	must(json.Unmarshal(call("GET", "/capabilities", nil, 200), &caps))
	pinned, e := os.ReadFile(dir + "/supervisor.pub")
	must(e)
	if !bytes.Equal(pinned, caps.SupervisorKey) {
		panic("supervisor key pin mismatch")
	}
	call("POST", "/evidence/v1/owners/"+id.Owner+"/requests/"+request+"/attempts/1", nil, 403)
	if caps.FullMemoryCheckpoint {
		panic("unsupported capability advertised")
	}
	spec := map[string]string{"kind": mode, "sourceDigest": caps.Config["sourceDigest"], "profileDigest": caps.Config["profileDigest"]}
	var record struct{ GuestUID, Backend string }
	if mode == "archived" {
		must(json.Unmarshal(call("GET", path, nil, 200), &record))
	} else {
		must(json.Unmarshal(call("POST", path, spec, 201), &record))
		call("POST", path, spec, 200)
		changed := map[string]string{"kind": mode, "sourceDigest": caps.Config["sourceDigest"], "profileDigest": "changed"}
		call("POST", path, changed, 409)
		changed = map[string]string{"kind": mode, "sourceDigest": "changed", "profileDigest": caps.Config["profileDigest"]}
		call("POST", path, changed, 409)
		call("POST", path+"/checkpoint", nil, 422)
		if mode == "session" {
			first := call("POST", path+"/inspect", nil, 200)
			second := call("POST", path+"/inspect", nil, 200)
			if len(first) == 0 || !bytes.Equal(first, second) {
				panic("session observations changed")
			}
			fmt.Println("PASS interactive consumer used persistent session through shared API")
		}
		call("POST", path+"/finish", nil, 200)
	}
	output := call("GET", path+"/evidence/output", nil, 200)
	logs := call("GET", path+"/evidence/logs", nil, 200)
	receipt := call("GET", path+"/evidence/receipt", nil, 200)
	var env evidence.Envelope
	must(json.Unmarshal(receipt, &env))
	body, e := evidence.Verify(env, map[string]ed25519.PublicKey{"supervisor": caps.SupervisorKey})
	must(e)
	expectedBackend := "kata-taskrun"
	if request == "session" {
		expectedBackend = "agent-sandbox"
	}
	if body.Owner != id.Owner || body.GuestUID != record.GuestUID || body.Backend != record.Backend || body.Backend != expectedBackend || body.Outcome != "Passed" || !body.RetainUntil.After(time.Now()) || body.IssuedAt.After(time.Now().Add(5*time.Second)) || body.Observed["pod_uid"] != record.GuestUID || body.Observed["runtime_class"] != "kata-prototype" || body.Observed["guest_kernel"] == "" || body.Observed["guest_kernel"] == body.Observed["node_kernel"] || body.Observed["profile_digest"] != caps.Config["profileDigest"] || body.Request != request || body.Attempt != 1 || body.ToolDigest != caps.Config["toolDigest"] || body.SourceDigest != spec["sourceDigest"] || body.ProfileDigest != spec["profileDigest"] || body.LogsDigest != evidence.Digest(logs) || body.ArtifactDigests["output.json"] != evidence.Digest(output) || body.Observed["cleanup"] != "guest-and-fence-removed" {
		panic("receipt binding mismatch")
	}
	fmt.Printf("PASS %s consumer; source/profile immutable; signed evidence available after %s removal\n", mode, body.Backend)
	fmt.Println(string(receipt))
}
