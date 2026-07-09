// Package imgcache downloads email images daemon-side, downscales them, and
// rewrites img tags to file:// paths. The UI never sees a network URL — QML's
// rich-text renderer fetches remote images from the render thread and
// segfaults quickshell, so every image must be local before HTML reaches it.
package imgcache

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"

	"golang.org/x/image/draw"

	_ "image/gif"

	_ "golang.org/x/image/webp"

	"mlqs/internal/debuglog"
)

const (
	maxWidth = 800
	maxBytes = 10 << 20
)

var client = &http.Client{Timeout: 8 * time.Second}

var (
	reRemoteImg  = regexp.MustCompile(`(?i)<img[^>]*\bsrc="(https?://[^"]+)"[^>]*/?>`)
	reWidthAttr  = regexp.MustCompile(`(?i)\bwidth="(\d+)"`)
	reHeightAttr = regexp.MustCompile(`(?i)\bheight="(\d+)"`)
)

// SizeAttrs carries the sender's intended display size onto a rewritten img
// tag (emails size 32px icons via width= on huge source images). Width wins;
// height alone only when no width — both would distort after our downscale.
func SizeAttrs(tag string) string {
	if m := reWidthAttr.FindStringSubmatch(tag); m != nil {
		w, _ := strconv.Atoi(m[1])
		if w > 0 {
			if w > 800 {
				w = 800
			}
			return fmt.Sprintf(` width="%d"`, w)
		}
	}
	if m := reHeightAttr.FindStringSubmatch(tag); m != nil {
		h, _ := strconv.Atoi(m[1])
		if h > 0 && h <= 800 {
			return fmt.Sprintf(` height="%d"`, h)
		}
	}
	return ""
}

func Dir() string {
	return filepath.Join(os.Getenv("HOME"), ".cache", "mlqs", "images")
}

func Key(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])[:20]
}

// Lookup returns the cached path for a key, or "".
func Lookup(key string) string {
	for _, ext := range []string{".jpg", ".png"} {
		p := filepath.Join(Dir(), key+ext)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// StoreBytes decodes, drops tracking pixels, downscales to maxWidth, and
// writes to the cache. Returns the local path.
func StoreBytes(key string, data []byte) (string, error) {
	img, format, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	b := img.Bounds()
	if b.Dx() <= 3 || b.Dy() <= 3 {
		return "", fmt.Errorf("tracking pixel")
	}
	if b.Dx() > maxWidth {
		nh := b.Dy() * maxWidth / b.Dx()
		dst := image.NewRGBA(image.Rect(0, 0, maxWidth, nh))
		draw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, b, draw.Over, nil)
		img = dst
	}
	if err := os.MkdirAll(Dir(), 0o700); err != nil {
		return "", err
	}
	ext, enc := ".png", func(w io.Writer) error { return png.Encode(w, img) }
	if format == "jpeg" {
		ext, enc = ".jpg", func(w io.Writer) error { return jpeg.Encode(w, img, &jpeg.Options{Quality: 85}) }
	}
	path := filepath.Join(Dir(), key+ext)
	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err := enc(f); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

func fetchURL(ctx context.Context, url string) (string, error) {
	key := Key(url)
	if p := Lookup(key); p != "" {
		return p, nil
	}
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) mlqs")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("http %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes))
	if err != nil {
		return "", err
	}
	return StoreBytes(key, data)
}

// RewriteRemote downloads every remote image concurrently and replaces its
// tag with a clean local one. Failed/blocked images keep their original tag —
// the sanitizer then reduces them to alt text or drops them.
func RewriteRemote(ctx context.Context, html string) string {
	matches := reRemoteImg.FindAllStringSubmatch(html, -1)
	if len(matches) == 0 {
		return html
	}
	paths := map[string]string{}
	for _, m := range matches {
		paths[m[1]] = ""
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for url := range paths {
		wg.Add(1)
		go func(url string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			p, err := fetchURL(ctx, url)
			if err != nil {
				debuglog.API("imgcache: %s: %v", url, err)
				return
			}
			mu.Lock()
			paths[url] = p
			mu.Unlock()
		}(url)
	}
	wg.Wait()
	return reRemoteImg.ReplaceAllStringFunc(html, func(tag string) string {
		m := reRemoteImg.FindStringSubmatch(tag)
		if p := paths[m[1]]; p != "" {
			return `<img src="file://` + p + `"` + SizeAttrs(tag) + `>`
		}
		return tag
	})
}
