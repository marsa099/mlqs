package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type updateRoundTripper func(*http.Request) (*http.Response, error)

func (f updateRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func withUpdateResponses(t *testing.T, responses map[string]string) {
	t.Helper()
	oldClient := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: updateRoundTripper(func(r *http.Request) (*http.Response, error) {
		body, ok := responses[r.URL.Path]
		if !ok {
			t.Fatalf("unexpected update request: %s", r.URL.Path)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
		}, nil
	})}
	t.Cleanup(func() { http.DefaultClient = oldClient })
}

func TestCheckForkDoesNotOfferAncestorAsUpdate(t *testing.T) {
	oldRev := gitRev
	gitRev = "feature"
	t.Cleanup(func() { gitRev = oldRev })

	// Fork main and upstream are both ancestors of the feature-branch build.
	// Their SHAs differ from gitRev, but neither has a commit missing from it.
	withUpdateResponses(t, map[string]string{
		"/repos/fork/mlqs/compare/feature...main":        `{"ahead_by":0,"head_commit":{"sha":"old-main"}}`,
		"/repos/fork/mlqs/compare/feature...daphen:main": `{"ahead_by":0,"head_commit":{"sha":"old-upstream"}}`,
	})

	target, ok := (&daemon{}).checkFork(context.Background(), "fork/mlqs", "daphen/mlqs")
	if !ok || target != "" {
		t.Fatalf("checkFork() = %q, %v; want no update", target, ok)
	}
}

func TestCheckForkOffersMissingForkCommit(t *testing.T) {
	oldRev := gitRev
	gitRev = "built"
	t.Cleanup(func() { gitRev = oldRev })

	withUpdateResponses(t, map[string]string{
		"/repos/fork/mlqs/compare/built...main": `{"ahead_by":1,"head_commit":{"sha":"new-fork-tip"}}`,
	})

	target, ok := (&daemon{}).checkFork(context.Background(), "fork/mlqs", "daphen/mlqs")
	if !ok || target != "new-fork-tip" {
		t.Fatalf("checkFork() = %q, %v; want new-fork-tip", target, ok)
	}
}
