package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	mode := flag.String("mode", "", "gateway, fixture, certs, request, stream, fronting, or raw")
	config := flag.String("config", "", "gateway configuration")
	dir := flag.String("dir", "/certs", "certificate directory")
	marker := flag.String("marker", "A", "fixture response marker")
	proxy := flag.String("proxy", "", "gateway URL")
	target := flag.String("url", "", "request URL or raw address")
	expect := flag.Int("expect", 200, "expected HTTP status")
	flag.Parse()
	var err error
	switch *mode {
	case "certs":
		err = makeCertificates(*dir)
	case "gateway":
		err = serveGateway(*config, *dir)
	case "validate":
		_, err = loadPolicy(*config)
	case "fixture":
		err = serveFixture(*dir, *marker)
	case "request", "stream", "fronting", "raw", "udp", "reach", "tcpstream":
		err = probe(*mode, *proxy, *target, *dir, *expect)
	default:
		err = fmt.Errorf("unknown mode %q", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
