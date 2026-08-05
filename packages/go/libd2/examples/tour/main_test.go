package main

import (
	"bytes"
	"flag"
	"os"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the snapshot of this example's output")

// The tour is what docs/usage/go.md is written from, so its output is snapshotted: a change in
// what the engine produces, or in what these bindings read out of it, shows up here as a diff
// against the numbers the guide quotes rather than silently making the guide wrong.
func TestTourOutput(t *testing.T) {
	const golden = "testdata/tour.txt"

	var buf bytes.Buffer
	if err := run(&buf); err != nil {
		t.Fatal(err)
	}

	if *update {
		if err := os.WriteFile(golden, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if got := buf.String(); got != string(want) {
		t.Errorf("tour output changed\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}
