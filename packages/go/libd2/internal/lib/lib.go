// Package lib finds, opens and binds the libd2 native shared libraries.
//
// Go has no equivalent of NuGet's runtimes/{rid}/native or a cargo build script: the source IS
// the distribution, so a native dependency has to arrive with it. Each subsystem package embeds
// exactly one shared library — its own, for the GOOS/GOARCH being built — and hands the bytes to
// Embed. Nothing else is compiled in, so a binary carries one platform's copy of the subsystems
// it actually imports.
//
// dlopen wants a path, not bytes, so an embedded library is written to the user cache directory
// keyed by content hash before it is opened. That is a one-time cost per version per machine.
package lib

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/ebitengine/purego"
)

// Library is an opened native shared library.
type Library struct {
	// Name is the base name without the platform's prefix/suffix, e.g. "d2drlg".
	Name string
	// Origin is where the library was loaded from, for diagnostics.
	Origin string

	handle uintptr
}

var (
	mu       sync.Mutex
	embedded = map[string][]byte{}
	opened   = map[string]*Library{}
)

// Embed registers the shared library bytes compiled into the binary for `name`. A subsystem
// package calls this from a generated, build-tagged init. Platforms with no shipped binary
// simply have no such file, which is why a missing platform is a clear runtime error rather
// than a build failure.
func Embed(name string, blob []byte) {
	mu.Lock()
	defer mu.Unlock()
	embedded[name] = blob
}

// FileName is the shared-library file name for `name` on the platform being built.
func FileName(name string) string {
	switch runtime.GOOS {
	case "windows":
		return name + ".dll"
	case "darwin", "ios":
		return "lib" + name + ".dylib"
	default:
		return "lib" + name + ".so"
	}
}

// Open loads the native library `name`, at most once per process. Later calls return the same
// handle, so two subsystems asking for the same library share it.
//
// It is resolved in this order, and the first that opens wins:
//
//	$LIBD2_D2DRLG_PATH   an exact file, uppercased from the library name
//	$LIBD2_PATH          a directory holding platform-named libraries
//	the embedded copy    extracted to the user cache directory
//	the system loader    by bare file name, honouring the usual search path
//
// The env vars come first deliberately: overriding the shipped binary with a local build is the
// thing you want most while working on libd2 itself, and it must not require a rebuild.
func Open(name string) (*Library, error) {
	mu.Lock()
	defer mu.Unlock()

	if l, ok := opened[name]; ok {
		return l, nil
	}

	var tried []string
	try := func(path, origin string) (*Library, bool) {
		h, err := openLibrary(path)
		if err != nil {
			tried = append(tried, fmt.Sprintf("%s (%s): %v", path, origin, err))
			return nil, false
		}
		l := &Library{Name: name, Origin: origin, handle: h}
		opened[name] = l
		return l, true
	}

	if p := os.Getenv(pathEnv(name)); p != "" {
		if l, ok := try(p, pathEnv(name)); ok {
			return l, nil
		}
	}
	if dir := os.Getenv("LIBD2_PATH"); dir != "" {
		if l, ok := try(filepath.Join(dir, FileName(name)), "LIBD2_PATH"); ok {
			return l, nil
		}
	}
	if blob := embedded[name]; len(blob) > 0 {
		path, err := extract(name, blob)
		if err != nil {
			tried = append(tried, fmt.Sprintf("embedded: %v", err))
		} else if l, ok := try(path, "embedded"); ok {
			return l, nil
		}
	} else {
		tried = append(tried, fmt.Sprintf("embedded: no %s/%s binary is compiled into this build",
			runtime.GOOS, runtime.GOARCH))
	}
	if l, ok := try(FileName(name), "system"); ok {
		return l, nil
	}

	return nil, fmt.Errorf("libd2: could not load the native %s library:\n  %s\nSet %s to a "+
		"built shared library, or LIBD2_PATH to a directory containing one.",
		name, strings.Join(tried, "\n  "), pathEnv(name))
}

func pathEnv(name string) string { return "LIBD2_" + strings.ToUpper(name) + "_PATH" }

// Bind points fn — a pointer to a func variable — at the exported C symbol `sym`.
//
// purego.RegisterLibFunc panics on a missing symbol, which for a version-mismatched library
// would surface as a stack trace instead of an explanation. Resolving the address first turns
// that into an error naming the symbol and where the library came from.
func Bind(l *Library, fn any, sym string) error {
	addr, err := symbol(l.handle, sym)
	if err != nil {
		return fmt.Errorf("libd2: %s is missing from %s (loaded from %s): %w", sym, l.Name, l.Origin, err)
	}
	purego.RegisterFunc(fn, addr)
	return nil
}

// extract writes an embedded library to the user cache directory and returns its path. The
// directory is keyed by the hash of the embedded bytes, so upgrading the Go module never reuses
// the previous binary and two versions can coexist.
func extract(name string, blob []byte) (string, error) {
	sum := sha256.Sum256(blob)
	dir := filepath.Join(cacheRoot(), "libd2-go", hex.EncodeToString(sum[:8]))
	path := filepath.Join(dir, FileName(name))

	// A file at a hash-keyed path is this exact build, and it only ever appears there complete
	// (written to a temp file and renamed), so finding it is the whole check. Not rewriting it
	// also keeps a second process from replacing a library the first one has mapped.
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	// Embedded libraries are gzipped: it roughly halves what every consumer's binary carries, and
	// costs one decompression the first time a given version runs on a machine. A library placed
	// here uncompressed by hand still works.
	if isGzip(blob) {
		plain, err := gunzip(blob)
		if err != nil {
			return "", fmt.Errorf("decompressing the embedded %s library: %w", name, err)
		}
		blob = plain
	}

	// Write and rename so a reader never sees a partial library, and two processes racing here
	// both end up with the same complete file.
	tmp, err := os.CreateTemp(dir, "."+FileName(name)+".*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(blob); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		// Windows refuses to replace a file another process has loaded. If the destination is
		// there, that other process already did our work.
		if _, serr := os.Stat(path); serr == nil {
			return path, nil
		}
		return "", err
	}
	return path, nil
}

func isGzip(b []byte) bool { return len(b) > 2 && b[0] == 0x1f && b[1] == 0x8b }

func gunzip(b []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}

func cacheRoot() string {
	if d, err := os.UserCacheDir(); err == nil {
		return d
	}
	return os.TempDir()
}

// Verify is a helper for the per-package ABI gate: a library whose ABI version differs from the
// one the bindings were written against is refused rather than called into.
func Verify(l *Library, got, want uint32) error {
	if got != want {
		return fmt.Errorf("libd2: native %s reports ABI %d, these bindings expect %d (loaded from %s)",
			l.Name, got, want, l.Origin)
	}
	return nil
}

var errNoSymbol = errors.New("symbol not found")
