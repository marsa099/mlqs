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
	// any remaining remote img after the explicit img pass — belt and braces
	reRemoteImg = regexp.MustCompile(`(?i)<img[^>]*src="https?:[^"]*"[^>]*/?>`)
	reRemoteSrc = regexp.MustCompile(`(?i)src="https?://[^"]*"`)
	reBlankImg  = regexp.MustCompile(`(?i)<img[^>]*src=""[^>]*/?>`)
	reManyBr    = regexp.MustCompile(`(?i)(<br\s*/?>\s*){3,}`)
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
	s = reAttrs.ReplaceAllString(s, "")
	s = reRemoteImg.ReplaceAllString(s, "<i>[image]</i>")
	s = reRemoteSrc.ReplaceAllString(s, `src=""`)
	s = reBlankImg.ReplaceAllString(s, "")
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
