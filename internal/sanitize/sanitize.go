// Package sanitize converts email HTML to the Qt rich-text subset by walking
// the parsed tree (x/net/html) and re-emitting only safe constructs.
// HARD RULE (spike-proven): a remote URL in an img src makes Qt fetch it from
// the render thread and segfault quickshell — only file:// images survive.
// imgcache rewrites downloadable images to file:// BEFORE this runs; whatever
// is still remote here failed to download and degrades to alt text.
package sanitize

import (
	stdhtml "html"
	"regexp"
	"strconv"
	"strings"

	xhtml "golang.org/x/net/html"
)

var (
	reEmptyA    = regexp.MustCompile(`(?i)<a[^>]*>(\s|&nbsp;|\x{00a0}|<br\s*/?>)*</a>`)
	reUnderline = regexp.MustCompile(`(?i)</?u>`)
	// (\s[^>]*)? not [^>]*: a bare [^>]* lets "i" swallow <img> and "b" <br>,
	// scrubbing every sized inline image as an "empty block"
	reEmptyBlock = regexp.MustCompile(`(?i)<(div|p|span|b|i|h3)(\s[^>]*)?>(\s|&nbsp;|\x{00a0}|<br\s*/?>)*</(div|p|span|b|i|h3)>`)
	reManyBr     = regexp.MustCompile(`(?i)(<br\s*/?>\s*){3,}`)
	reTags       = regexp.MustCompile(`<[^>]+>`)
)

// HTML sanitizes email HTML into Qt-safe rich text.
func HTML(s string) string {
	doc, err := xhtml.Parse(strings.NewReader(s))
	if err != nil {
		return Text(reTags.ReplaceAllString(s, " "))
	}
	var b strings.Builder
	render(doc, &b)
	out := reEmptyA.ReplaceAllString(b.String(), "")
	for i := 0; i < 4; i++ {
		prev := out
		out = reEmptyBlock.ReplaceAllString(out, "")
		if out == prev {
			break
		}
	}
	out = reManyBr.ReplaceAllString(out, "<br><br>")
	out = doubleEnt.Replace(out)
	return strings.TrimSpace(out)
}

var doubleEnt = strings.NewReplacer(
	"&amp;amp;", "&amp;", "&amp;lt;", "&lt;", "&amp;gt;", "&gt;",
	"&amp;quot;", "&quot;", "&amp;#", "&#")

// Text renders a plain-text body as rich text (escaped, line breaks kept).
func Text(s string) string {
	lines := strings.Split(s, "\n")
	var out []string
	inQuote := false
	for _, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), ">") {
			inQuote = true
			continue
		}
		if strings.TrimSpace(l) != "" {
			inQuote = false
		}
		if !inQuote {
			out = append(out, stdhtml.EscapeString(l))
		}
	}
	return `<div style="line-height:140%">` + strings.Join(out, "<br>") + "</div>"
}

// Rich picks the best body: sanitized HTML when present, else escaped text.
func Rich(bodyHTML, bodyText string) string {
	if strings.TrimSpace(bodyHTML) != "" {
		h, _ := trimQuotedHTML(bodyHTML)
		return HTML(h)
	}
	t, _ := trimQuotedText(bodyText)
	return Text(t)
}

func attr(n *xhtml.Node, name string) string {
	for _, a := range n.Attr {
		if strings.EqualFold(a.Key, name) {
			return a.Val
		}
	}
	return ""
}

// quoted detects the quoted-reply-history containers mail clients embed in
// every reply (Gmail gmail_quote, Outlook divRplyFwdMsg, Thunderbird cite
// prefix) — rendering them repeats the whole thread inside each message.
func quoted(n *xhtml.Node) bool {
	c := strings.ToLower(attr(n, "class"))
	id := strings.ToLower(attr(n, "id"))
	if n.Data == "blockquote" && strings.EqualFold(attr(n, "type"), "cite") {
		return true
	}
	return strings.Contains(c, "gmail_quote") || strings.Contains(c, "moz-cite-prefix") ||
		strings.Contains(c, "quoted-text") || id == "divrplyfwdmsg" || id == "isforwardcontent"
}

// Outlook doesn't mark its quotes — it opens a border-top separator div with
// a From:/Sent:/To: header block and pastes the whole prior thread after it.
// Truncate at the separator; same for the plain-text variants.
// `solid` must come right after border-top (Outlook's mso style order) and a
// From: block must follow — design emails use border-top bars decoratively.
var (
	reOutlookSep = regexp.MustCompile(`(?i)<div[^>]*border-top:\s*solid[^>]*>`)
	reOrigMsg    = regexp.MustCompile(`(?i)-+\s*Original Message\s*-+`)
	reOnWrote    = regexp.MustCompile(`(?i)^On .{5,120} wrote:\s*$`)
)

func outlookSepCut(s string) int {
	low := strings.ToLower(s)
	for _, m := range reOutlookSep.FindAllStringIndex(s, -1) {
		end := m[1] + 600
		if end > len(low) {
			end = len(low)
		}
		if strings.Contains(low[m[1]:end], "from:") {
			return m[0]
		}
	}
	return -1
}

func trimQuotedHTML(s string) (string, bool) {
	cut := len(s)
	if i := outlookSepCut(s); i >= 0 && i < cut {
		cut = i
	}
	if m := reOrigMsg.FindStringIndex(s); m != nil && m[0] < cut {
		cut = m[0]
	}
	if i := fromHeaderCut(s); i >= 0 && i < cut {
		cut = i
	}
	if cut < len(s) {
		return s[:cut], true
	}
	return s, false
}

// fromHeaderCut finds an Outlook-for-Mac style quote header (a From:
// followed closely by Date:/Sent: and Subject:, no separator div) and
// returns the enclosing block's start — the quote begins there.
func fromHeaderCut(s string) int {
	low := strings.ToLower(s)
	off := 0
	for {
		i := strings.Index(low[off:], "from:")
		if i < 0 {
			return -1
		}
		i += off
		end := i + 700
		if end > len(low) {
			end = len(low)
		}
		win := low[i:end]
		if (strings.Contains(win, "date:") || strings.Contains(win, "sent:")) &&
			strings.Contains(win, "subject:") {
			j := strings.LastIndex(low[:i], "<div")
			if k := strings.LastIndex(low[:i], "<p"); k > j {
				j = k
			}
			if j < 0 {
				j = i
			}
			return j
		}
		off = i + 5
	}
}

func trimQuotedText(s string) (string, bool) {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		t := strings.TrimSpace(l)
		hit := reOrigMsg.MatchString(t) || reOnWrote.MatchString(t)
		if !hit && strings.HasPrefix(t, "From: ") {
			for j := i + 1; j <= i+3 && j < len(lines); j++ {
				n := strings.TrimSpace(lines[j])
				if strings.HasPrefix(n, "Sent:") || strings.HasPrefix(n, "Date:") || strings.HasPrefix(n, "To:") {
					hit = true
					break
				}
			}
		}
		if hit {
			return strings.Join(lines[:i], "\n"), true
		}
	}
	return s, false
}

func hidden(n *xhtml.Node) bool {
	s := strings.ReplaceAll(strings.ToLower(attr(n, "style")), " ", "")
	return strings.Contains(s, "display:none") || strings.Contains(s, "visibility:hidden")
}

func children(n *xhtml.Node, b *strings.Builder) {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		render(c, b)
	}
}

var leadedBlocks = map[string]bool{
	"p": true, "div": true, "li": true, "blockquote": true, "pre": true, "h3": true,
}

func wrap(n *xhtml.Node, b *strings.Builder, tag string) {
	if leadedBlocks[tag] {
		b.WriteString(`<` + tag + ` style="line-height:140%">`)
	} else {
		b.WriteString("<" + tag + ">")
	}
	children(n, b)
	b.WriteString("</" + tag + ">")
}

func render(n *xhtml.Node, b *strings.Builder) {
	switch n.Type {
	case xhtml.TextNode:
		b.WriteString(stdhtml.EscapeString(n.Data))
	case xhtml.DocumentNode:
		children(n, b)
	case xhtml.ElementNode:
		switch n.Data {
		case "style", "script", "head", "title", "meta", "link", "noscript", "iframe", "object":
			return
		}
		if hidden(n) {
			return
		}
		if quoted(n) {
			return
		}
		switch n.Data {
		case "br":
			b.WriteString("<br>")
		case "hr":
			b.WriteString("<hr>")
		case "img":
			b.WriteString(imgHTML(n))
		case "a":
			href := attr(n, "href")
			if strings.HasPrefix(href, "http") || strings.HasPrefix(href, "mailto:") {
				b.WriteString(`<a href="` + stdhtml.EscapeString(href) + `">`)
				children(n, b)
				b.WriteString("</a>")
			} else {
				// dead link (js/in-page href): strip the underline too, so it
				// stops masquerading as clickable
				var tb strings.Builder
				children(n, &tb)
				b.WriteString(reUnderline.ReplaceAllString(tb.String(), ""))
			}
		case "b", "strong":
			wrap(n, b, "b")
		case "i", "em":
			wrap(n, b, "i")
		case "u":
			wrap(n, b, "u")
		case "s", "strike", "del":
			wrap(n, b, "s")
		case "h1", "h2", "h3":
			wrap(n, b, "h3")
		case "h4", "h5", "h6":
			b.WriteString("<div><b>")
			children(n, b)
			b.WriteString("</b></div>")
		case "ul", "ol", "li", "blockquote", "pre":
			wrap(n, b, n.Data)
		case "code":
			wrap(n, b, "code")
		case "p":
			wrap(n, b, "p")
		case "div", "section", "article", "aside", "main", "figure", "figcaption", "footer", "header":
			wrap(n, b, "div")
		case "table", "tbody", "thead", "tfoot":
			children(n, b)
		case "tr":
			rowHTML(n, b)
		case "td", "th":
			wrap(n, b, "div")
		default:
			children(n, b)
		}
	}
}

// rowHTML lays a table row out horizontally when its cells are small inline
// fragments (icon rows, button rows) and stacks them as blocks otherwise
// (text columns inlined together would interleave into garbage).
func rowHTML(n *xhtml.Node, b *strings.Builder) {
	var cells []string
	inlineOK := true
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type != xhtml.ElementNode || (c.Data != "td" && c.Data != "th") {
			continue
		}
		var cb strings.Builder
		if c.Data == "th" {
			cb.WriteString("<b>")
			children(c, &cb)
			cb.WriteString("</b>")
		} else {
			children(c, &cb)
		}
		s := cb.String()
		plain := strings.TrimSpace(reTags.ReplaceAllString(s, ""))
		if plain == "" && !strings.Contains(s, "<img") {
			continue
		}
		low := strings.ToLower(s)
		if len(plain) > 200 || strings.Contains(low, "<div") || strings.Contains(low, "<h3") ||
			strings.Contains(low, "<ul") || strings.Contains(low, "<blockquote") || strings.Contains(low, "<pre") {
			inlineOK = false
		}
		cells = append(cells, s)
	}
	switch {
	case len(cells) == 0:
	case len(cells) == 1:
		b.WriteString(`<div style="line-height:140%">` + cells[0] + "</div>")
	case inlineOK:
		b.WriteString(`<div style="line-height:140%">` + strings.Join(cells, "&nbsp;&nbsp;") + "</div>")
	default:
		for _, c := range cells {
			b.WriteString(`<div style="line-height:140%">` + c + "</div>")
		}
	}
}

func imgHTML(n *xhtml.Node) string {
	src := attr(n, "src")
	if strings.HasPrefix(src, "file://") {
		out := `<img src="` + stdhtml.EscapeString(src) + `"`
		if w, err := strconv.Atoi(attr(n, "width")); err == nil && w > 0 {
			if w > 800 {
				w = 800
			}
			out += ` width="` + strconv.Itoa(w) + `"`
		} else if h, err := strconv.Atoi(attr(n, "height")); err == nil && h > 0 && h <= 800 {
			out += ` height="` + strconv.Itoa(h) + `"`
		}
		return out + ">"
	}
	if alt := strings.TrimSpace(attr(n, "alt")); alt != "" && !junkAlt(alt) {
		return `<i><font color="#909090">` + stdhtml.EscapeString(alt) + `</font></i>`
	}
	return ""
}

// junkAlt: placeholder/filename-ish alt texts ("Logo", "product_image", "☆")
// read as noise when their image is gone; only descriptive alts are worth
// showing. Nulling them also collapses image-only anchors (reEmptyA).
func junkAlt(alt string) bool {
	if len([]rune(alt)) <= 2 {
		return true
	}
	if !strings.Contains(alt, " ") {
		return true
	}
	return false
}
