package main

import (
	"strings"
	"testing"

	"mlqs/internal/provider"
)

func TestMessagePlainPreservesCompleteBody(t *testing.T) {
	body := strings.Repeat("mail body ", 600)
	if got := messagePlain(provider.Message{BodyText: body}); got != strings.TrimSpace(body) {
		t.Fatalf("messagePlain truncated a %d-byte body to %d bytes", len(body), len(got))
	}
}

func TestBodyPlainStillCapsSummaryInput(t *testing.T) {
	body := strings.Repeat("x", 5000)
	if got := bodyPlain(provider.Message{BodyText: body}); len(got) != 4003 || !strings.HasSuffix(got, "…") {
		t.Fatalf("bodyPlain returned %d bytes without expected cap", len(got))
	}
}
