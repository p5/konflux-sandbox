package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"
)

func main() {
	if os.Args[1] == "notify" {
		proxy, err := url.Parse(os.Args[3])
		if err != nil {
			panic(err)
		}
		client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxy)}, Timeout: 5 * time.Second}
		response, err := client.Get(os.Args[2])
		if err != nil {
			panic(err)
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			panic(fmt.Sprintf("marker status %d", response.StatusCode))
		}
		io.Copy(io.Discard, response.Body)
		return
	}
	var mu sync.Mutex
	counts := map[string]int{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /counts", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(w).Encode(counts)
	})
	mux.HandleFunc("GET /{kind}/{request}", func(w http.ResponseWriter, r *http.Request) {
		kind, request := r.PathValue("kind"), r.PathValue("request")
		if (kind != "startup" && kind != "command") || (request != "finite" && request != "session") {
			http.Error(w, "marker denied", 403)
			return
		}
		mu.Lock()
		counts[kind+"/"+request]++
		mu.Unlock()
		fmt.Fprintln(w, "recorded")
	})
	if err := (&http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe(); err != nil {
		panic(err)
	}
}
