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
	reEmptyA     = regexp.MustCompile(`(?i)<a[^>]*>(\s|&nbsp;|\x{00a0}|<br\s*/?>)*</a>`)
	reEmptyBlock = regexp.MustCompile(`(?i)<(div|p|span|b|i|h3)>(\s|&nbsp;|\x{00a0}|<br\s*/?>)*</(div|p|span|b|i|h3)>`)
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
			if !inQuote {
				out = append(out, "<i>&#8942; quoted history</i>")
				inQuote = true
			}
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
		return HTML(bodyHTML)
	}
	return Text(bodyText)
}

func attr(n *xhtml.Node, name string) string {
	for _, a := range n.Attr {
		if strings.EqualFold(a.Key, name) {
			return a.Val
		}
	}
	return ""
}

const quoteMarker = `<div style="line-height:140%"><i>&#8942; quoted history</i></div>`

// quoted detects the quoted-reply-history containers mail clients embed in
// every reply (Gmail gmail_quote, Outlook divRplyFwdMsg, Thunderbird cite
// prefix) — rendering them repeats the whole thread inside each message.
func quoted(n *xhtml.Node) bool {
	c := strings.ToLower(attr(n, "class"))
	id := strings.ToLower(attr(n, "id"))
	return strings.Contains(c, "gmail_quote") || strings.Contains(c, "moz-cite-prefix") ||
		strings.Contains(c, "quoted-text") || id == "divrplyfwdmsg" || id == "isforwardcontent"
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
			b.WriteString(quoteMarker)
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
				children(n, b)
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
	if alt := strings.TrimSpace(attr(n, "alt")); alt != "" {
		return "<i>" + stdhtml.EscapeString(alt) + "</i>"
	}
	return ""
}
