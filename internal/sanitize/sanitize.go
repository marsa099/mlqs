// Package sanitize converts email HTML to the Qt rich-text subset.
// HARD RULE (spike-proven): a remote URL in an img src makes Qt fetch it
// from the render thread and segfault quickshell — no network URL may
// survive into the output, ever. "Load remote images" means the daemon
// downloads and rewrites to file:// before this output reaches the UI.
package sanitize

import (
	"html"
	"regexp"
	"strings"
)

var (
	reComment   = regexp.MustCompile(`(?s)<!--.*?-->`)
	reStyle     = regexp.MustCompile(`(?is)<style.*?</style>`)
	reScript    = regexp.MustCompile(`(?is)<script.*?</script>`)
	reHead      = regexp.MustCompile(`(?is)<head.*?</head>`)
	reHiddenDiv = regexp.MustCompile(`(?is)<div[^>]*display\s*:\s*none[^>]*>.*?</div>`)
	reTableTags = regexp.MustCompile(`(?i)</?(table|tbody|thead|tfoot|tr)[^>]*>`)
	reTdOpen    = regexp.MustCompile(`(?i)<td[^>]*>`)
	reTdClose   = regexp.MustCompile(`(?i)</td>`)
	reThOpen    = regexp.MustCompile(`(?i)<th[^>]*>`)
	reThClose   = regexp.MustCompile(`(?i)</th>`)
	// presentational attributes; href/src survive (src is handled below)
	reAttrs = regexp.MustCompile(`(?i)\s(style|class|id|width|height|align|valign|bgcolor|border|cellpadding|cellspacing|dir|lang|role|data-[a-z-]+|on[a-z]+)="[^"]*"`)
	// alignment/styling wrappers that fight the theme
	reCenter = regexp.MustCompile(`(?i)</?center[^>]*>`)
	reFont   = regexp.MustCompile(`(?i)</?font[^>]*>`)
	// images: file:// (daemon-cached) survive; everything else resolves to
	// alt text or vanishes. No network URL may remain (render-thread segfault).
	reFileImg   = regexp.MustCompile(`(?i)<img[^>]*src="file://[^"]*"[^>]*/?>`)
	reImgAlt    = regexp.MustCompile(`(?i)<img[^>]*\balt="([^"]+)"[^>]*/?>`)
	reAnyImg    = regexp.MustCompile(`(?i)<img[^>]*/?>`)
	reRemoteSrc = regexp.MustCompile(`(?i)src="https?://[^"]*"`)
	// empty anchors/blocks left behind once their image is gone
	reEmptyA     = regexp.MustCompile(`(?i)<a[^>]*>(\s|&nbsp;|<br\s*/?>)*</a>`)
	reEmptyBlock = regexp.MustCompile(`(?i)<(div|p|span|b|i)>(\s|&nbsp;|<br\s*/?>)*</(div|p|span|b|i)>`)
	reManyBr     = regexp.MustCompile(`(?i)(<br\s*/?>\s*){3,}`)
)

// HTML sanitizes email HTML into Qt-safe rich text.
func HTML(s string) string {
	s = reComment.ReplaceAllString(s, "")
	s = reStyle.ReplaceAllString(s, "")
	s = reScript.ReplaceAllString(s, "")
	s = reHead.ReplaceAllString(s, "")
	s = reHiddenDiv.ReplaceAllString(s, "")
	s = reTableTags.ReplaceAllString(s, "\n")
	s = reThOpen.ReplaceAllString(s, "<div><b>")
	s = reThClose.ReplaceAllString(s, "</b></div>")
	s = reTdOpen.ReplaceAllString(s, "<div>")
	s = reTdClose.ReplaceAllString(s, "</div>")
	// stash daemon-cached file:// images FIRST — their width/height attrs are
	// the sender's icon sizing and must survive the attribute strip below
	var stash []string
	s = reFileImg.ReplaceAllStringFunc(s, func(m string) string {
		stash = append(stash, m)
		return "\x00img\x00"
	})
	s = reAttrs.ReplaceAllString(s, "")
	s = reCenter.ReplaceAllString(s, "")
	s = reFont.ReplaceAllString(s, "")
	s = reImgAlt.ReplaceAllString(s, "<i>$1</i>")
	s = reAnyImg.ReplaceAllString(s, "")
	s = reRemoteSrc.ReplaceAllString(s, `src=""`)
	for _, img := range stash {
		s = strings.Replace(s, "\x00img\x00", img, 1)
	}

	// dropped images leave empty anchors and hollow blocks; a few passes
	// because emptying an inner block can empty its parent
	s = reEmptyA.ReplaceAllString(s, "")
	for i := 0; i < 4; i++ {
		prev := s
		s = reEmptyBlock.ReplaceAllString(s, "")
		if s == prev {
			break
		}
	}
	s = reManyBr.ReplaceAllString(s, "<br><br>")
	return strings.TrimSpace(s)
}

// Text renders a plain-text body as rich text (escaped, line breaks kept).
func Text(s string) string {
	return strings.ReplaceAll(html.EscapeString(s), "\n", "<br>")
}

// Rich picks the best body: sanitized HTML when present, else escaped text.
func Rich(bodyHTML, bodyText string) string {
	if strings.TrimSpace(bodyHTML) != "" {
		return HTML(bodyHTML)
	}
	return Text(bodyText)
}
