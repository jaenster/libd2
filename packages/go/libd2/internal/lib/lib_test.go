package lib

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestFileName(t *testing.T) {
	got := FileName("d2drlg")
	var want string
	switch runtime.GOOS {
	case "windows":
		want = "d2drlg.dll"
	case "darwin", "ios":
		want = "libd2drlg.dylib"
	default:
		want = "libd2drlg.so"
	}
	if got != want {
		t.Errorf("FileName(d2drlg) = %q, want %q", got, want)
	}
}

func TestPathEnv(t *testing.T) {
	if got, want := pathEnv("d2drlg"), "LIBD2_D2DRLG_PATH"; got != want {
		t.Errorf("pathEnv(d2drlg) = %q, want %q", got, want)
	}
}

// An unshipped library has to fail with an error that says what was tried and how to fix it. It
// is the message a user on a platform we have no binary for will see, so it is worth asserting
// rather than leaving to a nil dereference somewhere further in.
func TestOpenUnknownLibraryExplainsItself(t *testing.T) {
	_, err := Open("d2nosuchlibrary")
	if err == nil {
		t.Fatal("opening a library that does not exist succeeded")
	}
	msg := err.Error()
	for _, want := range []string{
		"d2nosuchlibrary",
		"no " + runtime.GOOS + "/" + runtime.GOARCH + " binary is compiled into this build",
		"LIBD2_D2NOSUCHLIBRARY_PATH",
		"LIBD2_PATH",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("the error does not mention %q:\n%s", want, msg)
		}
	}
}

// extract is what turns embedded bytes into something dlopen can take. It has to land an
// executable file, and asking twice has to reuse the first one rather than rewrite a library
// another process may already have mapped.
func TestExtract(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir()) // honoured by os.UserCacheDir on unix
	blob := []byte("not a real shared library, only bytes")

	path, err := extract("d2extracttest", blob)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(blob) {
		t.Errorf("extracted %q, want %q", got, blob)
	}
	if filepath.Base(path) != FileName("d2extracttest") {
		t.Errorf("extracted to %q, want a file named %q", filepath.Base(path), FileName("d2extracttest"))
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm()&0o111 == 0 {
			t.Errorf("extracted file mode is %v, want it executable", st.Mode().Perm())
		}
	}

	again, err := extract("d2extracttest", blob)
	if err != nil {
		t.Fatal(err)
	}
	if again != path {
		t.Errorf("second extract returned %q, want the first %q", again, path)
	}

	// Different bytes are a different build and must not land on top of the first one.
	other, err := extract("d2extracttest", append(blob, '!'))
	if err != nil {
		t.Fatal(err)
	}
	if other == path {
		t.Error("different library bytes extracted to the same path")
	}
}
