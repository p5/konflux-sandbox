package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func serveFixture(dir, marker string) error {
	var mu sync.Mutex
	records := map[string]string{}
	admin := http.NewServeMux()
	admin.HandleFunc("PUT /dns", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimSuffix(strings.ToLower(r.URL.Query().Get("name")), ".")
		ip := r.URL.Query().Get("ip")
		if net.ParseIP(ip) == nil {
			http.Error(w, "invalid IP", 400)
			return
		}
		mu.Lock()
		records[name] = ip
		mu.Unlock()
		w.WriteHeader(204)
	})
	admin.HandleFunc("GET /dns", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(w).Encode(records)
	})
	go func() {
		if err := http.ListenAndServe("127.0.0.1:9090", admin); err != nil {
			panic(err)
		}
	}()
	udp, err := net.ListenPacket("udp4", ":1053")
	if err != nil {
		return err
	}
	go func() {
		for {
			buf := make([]byte, 512)
			n, peer, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			query := buf[:n]
			if len(query) < 17 {
				continue
			}
			position := 12
			var labels []string
			for position < len(query) && query[position] > 0 {
				length := int(query[position])
				position++
				if length > 63 || position+length >= len(query) {
					position = len(query)
					break
				}
				labels = append(labels, string(query[position:position+length]))
				position += length
			}
			if position+5 > len(query) {
				continue
			}
			position++
			kind := binary.BigEndian.Uint16(query[position:])
			position += 4
			mu.Lock()
			address := records[strings.ToLower(strings.Join(labels, "."))]
			mu.Unlock()
			response := append([]byte(nil), query[:position]...)
			binary.BigEndian.PutUint16(response[2:], 0x8180)
			binary.BigEndian.PutUint16(response[6:], 0)
			binary.BigEndian.PutUint16(response[8:], 0)
			binary.BigEndian.PutUint16(response[10:], 0)
			if address == "" {
				binary.BigEndian.PutUint16(response[2:], 0x8183)
			}
			if ip := net.ParseIP(address).To4(); ip != nil && kind == 1 {
				binary.BigEndian.PutUint16(response[6:], 1)
				response = append(response, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 1, 0, 4)
				response = append(response, ip...)
			}
			udp.WriteTo(response, peer)
		}
	}()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "http://blocked.test:8080/", http.StatusFound)
			return
		}
		if r.URL.Path == "/stream" {
			w.Header().Set("Content-Type", "text/plain")
			for i := 0; ; i++ {
				if _, err := fmt.Fprintf(w, "stream-%s-%d\n", marker, i); err != nil {
					return
				}
				w.(http.Flusher).Flush()
				select {
				case <-r.Context().Done():
					return
				case <-time.After(100 * time.Millisecond):
				}
			}
		}
		fmt.Fprintf(w, "fixture-%s\n", marker)
	})
	go func() {
		if err := http.ListenAndServeTLS(":9443", filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key"), handler); err != nil {
			panic(err)
		}
	}()
	listener, err := net.Listen("tcp4", ":7070")
	if err != nil {
		return err
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); fmt.Fprintf(conn, "tcp-%s\n", marker); io.Copy(conn, conn) }()
		}
	}()
	return http.ListenAndServe(":8080", handler)
}
