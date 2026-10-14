package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func probe(mode, proxy, target, dir string, expect int) error {
	if mode == "udp" {
		connection, err := net.DialTimeout("udp", target, time.Second)
		if err != nil {
			return err
		}
		defer connection.Close()
		connection.SetDeadline(time.Now().Add(1500 * time.Millisecond))
		query := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'a', 'l', 'l', 'o', 'w', 'e', 'd', 4, 't', 'e', 's', 't', 0, 0, 1, 0, 1}
		if _, err := connection.Write(query); err != nil {
			return err
		}
		buf := make([]byte, 512)
		n, readErr := connection.Read(buf)
		if expect == 200 {
			if readErr != nil || n < 12 || buf[0] != 0x12 || buf[1] != 0x34 {
				return fmt.Errorf("baseline DNS unavailable: %v", readErr)
			}
			fmt.Printf("PASS baseline UDP DNS reachable: %s\n", target)
			return nil
		}
		if readErr == nil {
			return fmt.Errorf("unauthorized UDP DNS resolver reachable: %s", target)
		}
		fmt.Printf("PASS unauthorized UDP DNS resolver blocked: %s\n", target)
		return nil
	}
	if mode == "raw" || mode == "reach" {
		connection, err := net.DialTimeout("tcp", target, 1500*time.Millisecond)
		if connection != nil {
			connection.Close()
		}
		if mode == "reach" {
			if err != nil {
				return err
			}
			fmt.Printf("PASS baseline TCP destination reachable: %s\n", target)
			return nil
		}
		if err == nil {
			return fmt.Errorf("forbidden direct destination reachable: %s", target)
		}
		fmt.Printf("PASS direct connection blocked: %s\n", target)
		return nil
	}
	data, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(data)
	proxyURL, err := url.Parse(proxy)
	if err != nil {
		return err
	}
	if mode == "fronting" || mode == "tcpstream" || strings.HasPrefix(target, "tcp://") {
		connection, err := net.DialTimeout("tcp", proxyURL.Host, 3*time.Second)
		if err != nil {
			return err
		}
		defer connection.Close()
		connection.SetDeadline(time.Now().Add(5 * time.Second))
		address := strings.TrimPrefix(target, "tcp://")
		if mode == "fronting" {
			address = "allowed.test:9443"
		}
		fmt.Fprintf(connection, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", address, address)
		reader := bufio.NewReader(connection)
		response, err := http.ReadResponse(reader, nil)
		if err != nil {
			return err
		}
		if mode != "fronting" {
			if response.StatusCode != expect {
				return fmt.Errorf("CONNECT %s: got %d, expected %d", address, response.StatusCode, expect)
			}
			if expect == 200 {
				line, err := reader.ReadString('\n')
				if err != nil {
					return err
				}
				if !strings.Contains(line, "tcp-B") {
					return fmt.Errorf("unexpected raw fixture: %q", line)
				}
				if mode == "tcpstream" {
					fmt.Print(line)
					connection.SetDeadline(time.Now().Add(20 * time.Second))
					_, err := io.Copy(io.Discard, reader)
					if netErr, ok := errors.AsType[net.Error](err); ok && netErr.Timeout() {
						return errors.New("TCP stream survived revocation until timeout")
					}
					fmt.Println("PASS STREAM_CLOSED before client timeout")
				}
			}
			fmt.Printf("PASS explicit TCP grant: %s status=%d\n", address, response.StatusCode)
			return nil
		}
		if response.StatusCode != 200 {
			return fmt.Errorf("CONNECT: %s", response.Status)
		}
		name := "allowed.test"
		if strings.Contains(target, "sni") {
			name = "blocked.test"
		}
		clientTLS := &tls.Config{RootCAs: roots, ServerName: name, MinVersion: tls.VersionTLS13}
		if name == "blocked.test" {
			// Verify the CONNECT certificate while deliberately sending a different SNI.
			clientTLS.InsecureSkipVerify = true
			clientTLS.VerifyConnection = func(state tls.ConnectionState) error {
				_, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: roots, DNSName: "allowed.test"})
				return err
			}
		}
		secure := tls.Client(connection, clientTLS)
		err = secure.Handshake()
		if name == "blocked.test" {
			if err == nil {
				return errors.New("mismatching SNI accepted")
			}
			fmt.Println("PASS mismatching SNI rejected")
			return nil
		}
		if err != nil {
			return err
		}
		fmt.Fprint(secure, "GET / HTTP/1.1\r\nHost: blocked.test:9443\r\nConnection: close\r\n\r\n")
		response, err = http.ReadResponse(bufio.NewReader(secure), nil)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != 403 {
			return fmt.Errorf("fronted HTTP Host accepted: %s", response.Status)
		}
		fmt.Println("PASS HTTPS Host fronting rejected")
		return nil
	}
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}, DisableKeepAlives: true}, Timeout: 5 * time.Second}
	if mode == "stream" {
		client.Timeout = 20 * time.Second
	}
	response, err := client.Get(target)
	if err != nil {
		if expect == 0 {
			fmt.Printf("PASS unreachable gateway: %s\n", target)
			return nil
		}
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != expect {
		return fmt.Errorf("%s: got %d, expected %d", target, response.StatusCode, expect)
	}
	if mode == "stream" {
		scanner := bufio.NewScanner(response.Body)
		for scanner.Scan() {
			fmt.Println(scanner.Text())
		}
		if strings.Contains(fmt.Sprint(scanner.Err()), "deadline exceeded") {
			return errors.New("stream survived revocation until client timeout")
		}
		fmt.Println("PASS STREAM_CLOSED before client timeout")
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		return err
	}
	fmt.Printf("PASS request: %s status=%d body=%q\n", target, response.StatusCode, strings.TrimSpace(string(body)))
	return nil
}
