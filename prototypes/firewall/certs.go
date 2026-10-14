package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

func certificatePEM(cert []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert})
}

func keyPEM(key *ecdsa.PrivateKey) ([]byte, error) {
	b, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: b}), nil
}

func makeCertificates(dir string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "LOCAL FIREWALL PROTOTYPE"}, IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(2 * time.Hour)}
	b, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		return err
	}
	private, err := keyPEM(key)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "ca.crt"), certificatePEM(b), 0644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "ca.key"), private, 0600); err != nil {
		return err
	}
	ca, err = x509.ParseCertificate(b)
	if err != nil {
		return err
	}
	cert, err := issueServer(ca, key, []string{"allowed.test", "changing.test", "rebind.test", "shared.test", "blocked.test", "protected.test", "*.sub.test"})
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "server.crt"), certificatePEM(cert.Certificate[0]), 0644); err != nil {
		return err
	}
	private, err = keyPEM(cert.PrivateKey.(*ecdsa.PrivateKey))
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "server.key"), private, 0600)
}

func issueServer(ca *x509.Certificate, key *ecdsa.PrivateKey, names []string) (tls.Certificate, error) {
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: names[0]}, DNSNames: names, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	b, err := x509.CreateCertificate(rand.Reader, leaf, ca, &serverKey.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{b}, PrivateKey: serverKey}, nil
}
