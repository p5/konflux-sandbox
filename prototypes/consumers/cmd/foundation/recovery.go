package main

import (
	"crypto/ed25519"
	"maps"
	"os"
	"path/filepath"
	"time"

	"github.com/p5/konflux-sandbox/prototypes/consumers/journal"
	"github.com/p5/konflux-sandbox/prototypes/identity/pki"
)

func (f *Foundation) save(record *Record) {
	if f.durable {
		must(journal.Write(filepath.Join(f.state, "records", record.Request+".json"), record))
	}
}
func (f *Foundation) loadKey() {
	if !f.durable {
		return
	}
	path := filepath.Join(f.state, "supervisor-key.json")
	if _, err := os.Stat(path); err == nil {
		readJSON(path, &f.key)
		f.pub = f.key.Public().(ed25519.PublicKey)
	} else {
		must(journal.Write(path, f.key))
	}
}
func (f *Foundation) recover() {
	if !f.durable {
		return
	}
	files, err := filepath.Glob(filepath.Join(f.state, "records", "*.json"))
	must(err)
	for _, file := range files {
		record := new(Record)
		readJSON(file, record)
		f.records[record.Request] = record
		if record.Status == "UnknownOutcome" && record.Cleanup == "Verified" {
			continue
		}
		if record.Status == "Completed" {
			continue
		}
		f.active = record.Request
		var binding map[string]string
		path := filepath.Join(f.state, record.Request, "binding.json")
		if _, err := os.Stat(path); err != nil {
			record.Status = "UnknownOutcome"
			record.Cleanup = "BlockedMissingBinding"
			f.save(record)
			continue
		}
		readJSON(path, &binding)
		valid := record.Owner == "alice" && record.Attempt == 1 && record.Spec.SourceDigest == f.config.SourceDigest && record.Spec.ProfileDigest == f.config.ProfileDigest && record.ToolDigest == f.config.ToolDigest && maps.Equal(record.Binding, binding)
		if !valid {
			record.Status = "UnknownOutcome"
			record.Cleanup = "BlockedChangedBinding"
			f.save(record)
			continue
		}
		if record.Status == "Ready" {
			if err := f.backend("adopt", record.Request, record.Spec.Kind); err == nil {
				record.Control, err = pki.Issue(filepath.Join(f.state, "issuer"), pki.Identity{Owner: record.Owner, Request: record.Request, Attempt: "1", GuestUID: record.GuestUID}, "control", 5*time.Minute)
				must(err)
				continue
			}
			record.Status = "UnknownOutcome"
			record.Cleanup = "BlockedRuntimeBinding"
			f.save(record)
			continue
		}
		record.Status = "UnknownOutcome"
		record.Cleanup = "Pending"
		f.save(record)
		if err := f.backend("verify-cleanup", record.Request, record.Spec.Kind); err != nil {
			record.Cleanup = "BlockedRuntimeBinding"
			f.save(record)
			continue
		}
		if err := f.backend("stop", record.Request, record.Spec.Kind); err != nil {
			record.Cleanup = "BlockedDisposal"
			f.save(record)
			continue
		}
		record.Cleanup = "Verified"
		f.active = ""
		f.save(record)
	}
}
