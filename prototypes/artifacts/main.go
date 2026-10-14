package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type entry struct {
	Path   string `json:"path"`
	Kind   string `json:"kind"`
	Mode   int64  `json:"mode"`
	Digest string `json:"digest,omitempty"`
	Target string `json:"target,omitempty"`
	Data   []byte `json:"-"`
}

type manifest struct {
	Version   string   `json:"version"`
	Base      string   `json:"base"`
	Entries   []entry  `json:"entries"`
	Deletions []string `json:"deletions"`
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func digest(b []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(b)) }
func git(dir string, args ...string) []byte {
	c := exec.Command("git", append([]string{"-C", dir}, args...)...)
	c.Env = append(os.Environ(), "GIT_AUTHOR_DATE=2026-10-14T00:00:00Z", "GIT_COMMITTER_DATE=2026-10-14T00:00:00Z")
	b, err := c.CombinedOutput()
	if err != nil {
		panic(string(b))
	}
	return b
}
func names(b []byte) []string { return strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00") }
func canonical(p string) bool {
	return p != "" && p != "." && !strings.Contains(p, "\\") && !path.IsAbs(p) && path.Clean(p) == p && p != ".." && !strings.HasPrefix(p, "../")
}

func capture(dir string, selected []string) (manifest, []byte) {
	root, err := os.OpenRoot(dir)
	must(err)
	defer root.Close()
	m := manifest{Version: "prototype.source.v1", Base: strings.TrimSpace(string(git(dir, "rev-parse", "HEAD"))), Entries: []entry{}, Deletions: []string{}}
	tracked := names(git(dir, "ls-files", "-z"))
	all := slices.Concat(tracked, selected)
	slices.Sort(all)
	all = slices.Compact(all)
	for _, p := range all {
		if !canonical(p) || p == ".git" || strings.HasPrefix(p, ".git/") {
			panic("invalid selected path")
		}
		st, err := root.Lstat(p)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		must(err)
		e := entry{Path: p, Mode: 0644, Kind: "file"}
		switch {
		case st.Mode()&os.ModeSymlink != 0:
			e.Kind = "symlink"
			e.Mode = 0777
			e.Target, err = root.Readlink(p)
			must(err)
		case st.Mode().IsRegular():
			if st.Mode()&0111 != 0 {
				e.Mode = 0755
			}
			e.Data, err = root.ReadFile(p)
			must(err)
			e.Digest = digest(e.Data)
		default:
			panic("unsupported source file")
		}
		m.Entries = append(m.Entries, e)
	}
	for _, p := range names(git(dir, "ls-tree", "-r", "--name-only", "-z", "HEAD")) {
		if _, err := root.Lstat(p); errors.Is(err, os.ErrNotExist) {
			m.Deletions = append(m.Deletions, p)
		}
	}
	slices.Sort(m.Deletions)
	b, err := json.Marshal(m)
	must(err)
	return m, b
}

func archive(entries []entry) []byte {
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for _, e := range entries {
		h := &tar.Header{Name: e.Path, Mode: e.Mode, Size: int64(len(e.Data)), Typeflag: tar.TypeReg, Format: tar.FormatPAX}
		if e.Kind == "symlink" {
			h.Typeflag = tar.TypeSymlink
			h.Linkname = e.Target
			h.Size = 0
		}
		must(w.WriteHeader(h))
		if h.Typeflag == tar.TypeReg {
			_, err := w.Write(e.Data)
			must(err)
		}
	}
	must(w.Close())
	return b.Bytes()
}

func importArchive(b []byte, dest string) error {
	r := tar.NewReader(bytes.NewReader(b))
	var entries []entry
	seen := map[string]bool{}
	links := map[string]bool{}
	var total int64
	for {
		h, err := r.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if !canonical(h.Name) || seen[h.Name] {
			return fmt.Errorf("unsafe or duplicate path %q", h.Name)
		}
		seen[h.Name] = true
		if len(seen) > 1000 || h.Size < 0 || h.Size > 16<<20 || total+h.Size > 16<<20 {
			return errors.New("archive limit")
		}
		total += h.Size
		e := entry{Path: h.Name, Mode: h.Mode & 0777}
		switch h.Typeflag {
		case tar.TypeReg, tar.TypeRegA:
			e.Kind = "file"
			e.Data, err = io.ReadAll(io.LimitReader(r, 16<<20))
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			if path.IsAbs(h.Linkname) || strings.Contains(h.Linkname, "\\") || !canonical(path.Join(path.Dir(h.Name), h.Linkname)) {
				return errors.New("escaping symlink")
			}
			e.Kind = "symlink"
			e.Target = h.Linkname
			links[h.Name] = true
		default:
			return fmt.Errorf("unsupported archive type %d", h.Typeflag)
		}
		entries = append(entries, e)
	}
	for _, e := range entries {
		for p := path.Dir(e.Path); p != "."; p = path.Dir(p) {
			if links[p] {
				return errors.New("symlink parent")
			}
		}
	}
	if err := os.Mkdir(dest, 0700); err != nil {
		return err
	}
	root, err := os.OpenRoot(dest)
	if err != nil {
		return err
	}
	defer root.Close()
	for _, e := range entries {
		if err := root.MkdirAll(path.Dir(e.Path), 0700); err != nil {
			return err
		}
		if e.Kind == "symlink" {
			if err := root.Symlink(e.Target, e.Path); err != nil {
				return err
			}
			continue
		}
		f, err := root.OpenFile(e.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(e.Mode))
		if err != nil {
			return err
		}
		_, err = f.Write(e.Data)
		cerr := f.Close()
		if err != nil {
			return err
		}
		if cerr != nil {
			return cerr
		}
	}
	return nil
}

func validateContent(dir string, m manifest) error {
	expected := map[string]entry{}
	for _, e := range m.Entries {
		expected[e.Path] = e
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	err = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		e, ok := expected[rel]
		if !ok {
			return errors.New("unexpected source entry")
		}
		delete(expected, rel)
		st, err := root.Lstat(rel)
		if err != nil {
			return err
		}
		if e.Kind == "symlink" {
			target, err := root.Readlink(rel)
			if err != nil {
				return err
			}
			if target != e.Target {
				return errors.New("symlink identity mismatch")
			}
			return nil
		}
		b, err := root.ReadFile(rel)
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() || digest(b) != e.Digest || int64(st.Mode().Perm()) != e.Mode {
			return errors.New("source content or mode mismatch")
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(expected) != 0 {
		return errors.New("missing source entry")
	}
	return nil
}

func main() {
	if len(os.Args) == 6 && os.Args[1] == "import-verify" {
		b := mustRead(os.Args[3])
		if digest(b) != os.Args[5] {
			panic("manifest identity mismatch")
		}
		var m manifest
		must(json.Unmarshal(b, &m))
		if m.Version != "prototype.source.v1" {
			panic("unsupported source manifest")
		}
		must(importArchive(mustRead(os.Args[2]), os.Args[4]))
		must(validateContent(os.Args[4], m))
		fmt.Println("PASS source import; manifest identity, bounded archive, and restored content verified")
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "receipts" {
		runReceipts(os.Args[2])
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "import" {
		must(importArchive(mustRead(os.Args[2]), os.Args[3]))
		return
	}
	if len(os.Args) != 2 {
		panic("usage: artifacts STATE_DIR | artifacts import TAR DEST | artifacts import-verify TAR MANIFEST DEST EXPECTED_MANIFEST_DIGEST")
	}
	state, err := filepath.Abs(os.Args[1])
	must(err)
	must(os.MkdirAll(state, 0700))
	dir, err := os.MkdirTemp(state, "source-")
	must(err)
	git(dir, "init", "-q")
	git(dir, "config", "user.name", "Prototype")
	git(dir, "config", "user.email", "prototype.invalid@example.invalid")
	write := func(p, s string) { must(os.WriteFile(filepath.Join(dir, p), []byte(s), 0644)) }
	write("staged.txt", "base\n")
	write("unstaged.txt", "base\n")
	write("deleted.txt", "base\n")
	write("run.sh", "#!/bin/sh\nexit 0\n")
	git(dir, "add", ".")
	git(dir, "commit", "-qm", "chore(prototype): create source fixture")
	write("staged.txt", "staged\n")
	git(dir, "add", "staged.txt")
	write("unstaged.txt", "unstaged\n")
	must(os.Remove(filepath.Join(dir, "deleted.txt")))
	write("selected.txt", "selected\n")
	write("excluded.txt", "private synthetic\n")
	must(os.Chmod(filepath.Join(dir, "run.sh"), 0755))
	must(os.Symlink("unstaged.txt", filepath.Join(dir, "link")))
	selected := []string{"selected.txt", "link"}
	m, b := capture(dir, selected)
	baseline := digest(b)
	must(os.WriteFile(filepath.Join(state, "manifest.json"), b, 0600))
	a := archive(m.Entries)
	must(os.WriteFile(filepath.Join(state, "source.tar"), a, 0600))
	must(importArchive(a, filepath.Join(dir, "restored")))
	results := map[string]any{"source_digest": baseline, "archive_digest": digest(a), "entries": len(m.Entries), "deletions": m.Deletions, "source_dir": dir}
	for _, e := range m.Entries {
		p := filepath.Join(dir, "restored", e.Path)
		if e.Kind == "symlink" {
			target, err := os.Readlink(p)
			must(err)
			if target != e.Target {
				panic("symlink target changed")
			}
			continue
		}
		st, err := os.Stat(p)
		must(err)
		if digest(mustRead(p)) != e.Digest || int64(st.Mode().Perm()) != e.Mode {
			panic("restored source changed")
		}
	}
	results["restored_bytes_modes_and_symlinks_match"] = true
	must(validateContent(filepath.Join(dir, "restored"), m))
	must(os.WriteFile(filepath.Join(dir, "restored", "staged.txt"), []byte("tampered\n"), 0644))
	results["manifest_rejects_changed_content"] = validateContent(filepath.Join(dir, "restored"), m) != nil
	must(os.WriteFile(filepath.Join(dir, "restored", "staged.txt"), []byte("staged\n"), 0644))
	must(os.Remove(filepath.Join(dir, "restored", "selected.txt")))
	results["manifest_rejects_missing_content"] = validateContent(filepath.Join(dir, "restored"), m) != nil
	results["deleted_path_recorded"] = slices.Equal(m.Deletions, []string{"deleted.txt"})
	_, err = os.Stat(filepath.Join(dir, "restored", "excluded.txt"))
	results["excluded_absent"] = errors.Is(err, os.ErrNotExist)
	must(os.Chtimes(filepath.Join(dir, "unstaged.txt"), time.Now(), time.Now().Add(time.Hour)))
	_, stable := capture(dir, selected)
	results["timestamps_do_not_change_identity"] = digest(stable) == baseline
	git(dir, "add", "staged.txt", "unstaged.txt")
	_, stable = capture(dir, selected)
	results["index_staging_does_not_change_selected_tree"] = digest(stable) == baseline
	write("unstaged.txt", "modified again\n")
	_, changed := capture(dir, selected)
	results["content_changes_identity"] = digest(changed) != baseline
	must(os.Chmod(filepath.Join(dir, "run.sh"), 0644))
	_, mode := capture(dir, selected)
	results["executable_bit_changes_identity"] = digest(mode) != digest(changed)
	write("excluded.txt", "changed excluded\n")
	_, excluded := capture(dir, selected)
	results["excluded_changes_do_not_change_identity"] = digest(excluded) == digest(mode)
	_, included := capture(dir, append(selected, "excluded.txt"))
	results["selection_changes_identity"] = digest(included) != digest(excluded)
	must(os.Remove(filepath.Join(dir, "link")))
	must(os.Symlink("staged.txt", filepath.Join(dir, "link")))
	_, retargeted := capture(dir, selected)
	results["symlink_target_changes_identity"] = digest(retargeted) != digest(excluded)
	negatives := map[string][]entry{
		"traversal": {{Path: "../outside", Kind: "file"}}, "absolute": {{Path: "/outside", Kind: "file"}},
		"symlink_escape": {{Path: "link", Kind: "symlink", Target: "../../outside"}},
		"symlink_parent": {{Path: "dir", Kind: "symlink", Target: "other"}, {Path: "dir/payload", Kind: "file"}},
		"duplicate":      {{Path: "same", Kind: "file"}, {Path: "same", Kind: "file"}},
	}
	for name, es := range negatives {
		err := importArchive(archive(es), filepath.Join(dir, "negative-"+name))
		if err == nil {
			panic("negative import accepted")
		}
		results["rejected_"+name] = err.Error()
	}
	for name, h := range map[string]*tar.Header{
		"hardlink": {Name: "hard", Typeflag: tar.TypeLink, Linkname: "safe"},
		"device":   {Name: "device", Typeflag: tar.TypeChar},
		"oversize": {Name: "large", Typeflag: tar.TypeReg, Size: 17 << 20},
	} {
		var b bytes.Buffer
		w := tar.NewWriter(&b)
		must(w.WriteHeader(h))
		err := importArchive(b.Bytes(), filepath.Join(dir, "negative-"+name))
		if err == nil {
			panic("negative archive header accepted")
		}
		results["rejected_"+name] = err.Error()
	}
	for k, v := range results {
		if ok, isBool := v.(bool); isBool && !ok {
			panic(k + " failed")
		}
	}
	out, err := json.MarshalIndent(results, "", "  ")
	must(err)
	fmt.Println(string(out))
}

func mustRead(p string) []byte { b, err := os.ReadFile(p); must(err); return b }
