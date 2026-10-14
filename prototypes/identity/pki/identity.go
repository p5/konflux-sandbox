package pki

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type Identity struct {
	Owner    string `json:"owner"`
	Request  string `json:"request"`
	Attempt  string `json:"attempt"`
	GuestUID string `json:"guestUID"`
}

func (i Identity) URI() string {
	return fmt.Sprintf("spiffe://konflux-sandbox.prototype/owner/%s/request/%s/attempt/%s/guest/%s", i.Owner, i.Request, i.Attempt, i.GuestUID)
}

func Parse(c *x509.Certificate, role string) (Identity, error) {
	var i Identity
	if len(c.URIs) != 1 || len(c.Subject.OrganizationalUnit) != 1 || c.Subject.OrganizationalUnit[0] != role {
		return i, fmt.Errorf("unexpected identity role")
	}
	u := c.URIs[0]
	p := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	if u.Scheme != "spiffe" || u.Host != "konflux-sandbox.prototype" || len(p) != 8 || p[0] != "owner" || p[2] != "request" || p[4] != "attempt" || p[6] != "guest" {
		return i, fmt.Errorf("invalid identity URI")
	}
	i = Identity{p[1], p[3], p[5], p[7]}
	for _, s := range []string{i.Owner, i.Request, i.Attempt, i.GuestUID} {
		if !regexp.MustCompile(`^[a-z0-9-]+$`).MatchString(s) {
			return Identity{}, fmt.Errorf("invalid identity segment")
		}
	}
	if time.Now().Before(c.NotBefore) || !time.Now().Before(c.NotAfter) {
		return Identity{}, fmt.Errorf("identity expired")
	}
	return i, nil
}

type Files struct {
	CA         string `json:"ca"`
	Cert       string `json:"cert"`
	Key        string `json:"key"`
	ServerName string `json:"serverName"`
	URI        string `json:"uri"`
}

func Issue(state string, i Identity, role string, ttl time.Duration) (Files, error) {
	var f Files
	if err := os.MkdirAll(state, 0700); err != nil {
		return f, err
	}
	caPath, keyPath := filepath.Join(state, "ca.crt"), filepath.Join(state, "ca.key")
	if _, err := os.Stat(caPath); os.IsNotExist(err) {
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return f, err
		}
		t := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "local prototype issuer"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
		der, err := x509.CreateCertificate(rand.Reader, t, t, pub, key)
		if err != nil {
			return f, err
		}
		kb, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return f, err
		}
		if err = os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
			return f, err
		}
		if err = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: kb}), 0600); err != nil {
			return f, err
		}
	}
	cb, err := os.ReadFile(caPath)
	if err != nil {
		return f, err
	}
	cp, _ := pem.Decode(cb)
	if cp == nil {
		return f, fmt.Errorf("invalid CA")
	}
	ca, err := x509.ParseCertificate(cp.Bytes)
	if err != nil {
		return f, err
	}
	kb, err := os.ReadFile(keyPath)
	if err != nil {
		return f, err
	}
	kp, _ := pem.Decode(kb)
	if kp == nil {
		return f, fmt.Errorf("invalid CA key")
	}
	cak, err := x509.ParsePKCS8PrivateKey(kp.Bytes)
	if err != nil {
		return f, err
	}
	u, err := url.Parse(i.URI())
	if err != nil {
		return f, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return f, err
	}
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return f, err
	}
	dns := "guest-" + i.GuestUID + ".prototype"
	if role == "broker" {
		dns = "broker.prototype"
	}
	if role == "gateway" {
		dns = "gateway.prototype"
	}
	t := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{OrganizationalUnit: []string{role}}, URIs: []*url.URL{u}, DNSNames: []string{dns}, NotBefore: time.Now().Add(-time.Second), NotAfter: time.Now().Add(ttl), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	if _, err = Parse(t, role); err != nil {
		return f, err
	}
	der, err := x509.CreateCertificate(rand.Reader, t, ca, pub, cak)
	if err != nil {
		return f, err
	}
	kb, err = x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return f, err
	}
	prefix := filepath.Join(state, strings.Join([]string{role, i.Owner, i.Request, i.Attempt, i.GuestUID}, "-"))
	f = Files{caPath, prefix + ".crt", prefix + ".key", dns, i.URI()}
	if err = os.WriteFile(f.Cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		return f, err
	}
	err = os.WriteFile(f.Key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: kb}), 0600)
	return f, err
}

func TLS(ca, cert, key string) (*tls.Config, error) {
	b, err := os.ReadFile(ca)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(b) {
		return nil, fmt.Errorf("invalid CA bundle")
	}
	pair, err := tls.LoadX509KeyPair(cert, key)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: pool, ClientCAs: pool, Certificates: []tls.Certificate{pair}}, nil
}
