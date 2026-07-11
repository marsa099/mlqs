// Package gcal implements a Google Calendar REST adapter. Raw HTTP like the
// gmail package — same token source, same hardened transport.
package gcal

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/oauth2"

	"mlqs/internal/httpx"
	"mlqs/internal/provider"
)

const apiBase = "https://www.googleapis.com/calendar/v3"

type Client struct {
	hc *http.Client
}

func New(ctx context.Context, ts oauth2.TokenSource) *Client {
	return &Client{hc: &http.Client{
		Transport: &oauth2.Transport{Source: ts, Base: httpx.Transport()},
		Timeout:   60 * time.Second,
	}}
}

func (c *Client) do(ctx context.Context, method, path string, q url.Values, body, out any) error {
	u := apiBase + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rdr)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	rb, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 300 {
		msg := string(rb)
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(rb, &e) == nil && e.Error.Message != "" {
			msg = e.Error.Message
		}
		return fmt.Errorf("gcal: %d %s", resp.StatusCode, msg)
	}
	if out != nil {
		return json.Unmarshal(rb, out)
	}
	return nil
}

// Aliases into the vendor-blind types — Graph implements the same shapes.
type (
	Calendar = provider.Calendar
	Attendee = provider.CalAttendee
	Event    = provider.CalEvent
	NewEvent = provider.NewEvent
)

type apiTime struct {
	Date     string `json:"date,omitempty"`
	DateTime string `json:"dateTime,omitempty"`
	TimeZone string `json:"timeZone,omitempty"`
}

type apiAttendee struct {
	Email          string `json:"email"`
	DisplayName    string `json:"displayName,omitempty"`
	ResponseStatus string `json:"responseStatus,omitempty"`
	Self           bool   `json:"self,omitempty"`
	Optional       bool   `json:"optional,omitempty"`
	Resource       bool   `json:"resource,omitempty"`
}

type apiEvent struct {
	ID          string        `json:"id"`
	Status      string        `json:"status"`
	Summary     string        `json:"summary"`
	Description string        `json:"description,omitempty"`
	Location    string        `json:"location,omitempty"`
	Start       apiTime       `json:"start"`
	End         apiTime       `json:"end"`
	Attendees   []apiAttendee `json:"attendees,omitempty"`
	Organizer   *struct {
		Email       string `json:"email"`
		DisplayName string `json:"displayName"`
	} `json:"organizer,omitempty"`
	HangoutLink    string `json:"hangoutLink,omitempty"`
	HTMLLink       string `json:"htmlLink,omitempty"`
	ICalUID        string `json:"iCalUID,omitempty"`
	ConferenceData *struct {
		EntryPoints []struct {
			Type string `json:"entryPointType"`
			URI  string `json:"uri"`
		} `json:"entryPoints"`
	} `json:"conferenceData,omitempty"`
}

func parseAPITime(t apiTime) (time.Time, bool) {
	if t.DateTime != "" {
		ts, err := time.Parse(time.RFC3339, t.DateTime)
		if err == nil {
			return ts.Local(), false
		}
	}
	if t.Date != "" {
		ts, err := time.ParseInLocation("2006-01-02", t.Date, time.Local)
		if err == nil {
			return ts, true
		}
	}
	return time.Time{}, false
}

func flatten(calID string, e apiEvent) Event {
	start, allDay := parseAPITime(e.Start)
	end, _ := parseAPITime(e.End)
	ev := Event{
		ID: e.ID, CalID: calID, Title: e.Summary, Location: e.Location,
		Start: start, End: end, AllDay: allDay,
		MeetLink: e.HangoutLink, HTMLLink: e.HTMLLink, ICalUID: e.ICalUID,
	}
	if ev.Title == "" {
		ev.Title = "(untitled)"
	}
	if ev.MeetLink == "" && e.ConferenceData != nil {
		for _, ep := range e.ConferenceData.EntryPoints {
			if ep.Type == "video" {
				ev.MeetLink = ep.URI
				break
			}
		}
	}
	if e.Organizer != nil {
		ev.Organizer = e.Organizer.DisplayName
		if ev.Organizer == "" {
			ev.Organizer = e.Organizer.Email
		}
	}
	for _, a := range e.Attendees {
		if a.Resource {
			continue
		}
		ev.Attendees = append(ev.Attendees, Attendee{
			Email: a.Email, Name: a.DisplayName, Status: a.ResponseStatus, Self: a.Self,
		})
		if a.Self {
			ev.MyStatus = a.ResponseStatus
		}
	}
	return ev
}

func (c *Client) Calendars(ctx context.Context) ([]Calendar, error) {
	var res struct {
		Items []struct {
			ID       string `json:"id"`
			Summary  string `json:"summary"`
			Primary  bool   `json:"primary"`
			Selected bool   `json:"selected"`
			BgColor  string `json:"backgroundColor"`
			Role     string `json:"accessRole"`
		} `json:"items"`
	}
	if err := c.do(ctx, "GET", "/users/me/calendarList", nil, nil, &res); err != nil {
		return nil, err
	}
	var out []Calendar
	for _, it := range res.Items {
		if !it.Selected && !it.Primary {
			continue
		}
		out = append(out, Calendar{ID: it.ID, Name: it.Summary, Primary: it.Primary, Color: it.BgColor, Role: it.Role})
	}
	return out, nil
}

// Events lists expanded (single) events in [from, to) for one calendar.
func (c *Client) Events(ctx context.Context, calID string, from, to time.Time) ([]Event, error) {
	q := url.Values{
		"timeMin":      {from.Format(time.RFC3339)},
		"timeMax":      {to.Format(time.RFC3339)},
		"singleEvents": {"true"},
		"orderBy":      {"startTime"},
		"maxResults":   {"250"},
	}
	var res struct {
		Items []apiEvent `json:"items"`
	}
	if err := c.do(ctx, "GET", "/calendars/"+url.PathEscape(calID)+"/events", q, nil, &res); err != nil {
		return nil, err
	}
	var out []Event
	for _, e := range res.Items {
		if e.Status == "cancelled" {
			continue
		}
		out = append(out, flatten(calID, e))
	}
	return out, nil
}

// RSVP sets my attendee responseStatus. PATCH replaces the whole attendees
// array, so the current list is fetched and re-sent with only mine changed.
func (c *Client) RSVP(ctx context.Context, calID, eventID, status string) error {
	var e apiEvent
	if err := c.do(ctx, "GET", "/calendars/"+url.PathEscape(calID)+"/events/"+url.PathEscape(eventID), nil, nil, &e); err != nil {
		return err
	}
	found := false
	for i := range e.Attendees {
		if e.Attendees[i].Self {
			e.Attendees[i].ResponseStatus = status
			found = true
		}
	}
	if !found {
		return fmt.Errorf("not an attendee of this event")
	}
	q := url.Values{"sendUpdates": {"all"}}
	body := map[string]any{"attendees": e.Attendees}
	return c.do(ctx, "PATCH", "/calendars/"+url.PathEscape(calID)+"/events/"+url.PathEscape(eventID), q, body, nil)
}

// FindByICalUID resolves an .ics invite's UID to the event on this calendar.
func (c *Client) FindByICalUID(ctx context.Context, calID, uid string) (*Event, error) {
	q := url.Values{"iCalUID": {uid}}
	var res struct {
		Items []apiEvent `json:"items"`
	}
	if err := c.do(ctx, "GET", "/calendars/"+url.PathEscape(calID)+"/events", q, nil, &res); err != nil {
		return nil, err
	}
	for _, e := range res.Items {
		if e.Status != "cancelled" {
			ev := flatten(calID, e)
			return &ev, nil
		}
	}
	return nil, fmt.Errorf("no event for invite (uid %s)", uid)
}

func (c *Client) Create(ctx context.Context, calID string, ne NewEvent) (*Event, error) {
	body := map[string]any{
		"summary":     ne.Title,
		"location":    ne.Location,
		"description": ne.Notes,
		"start":       map[string]string{"dateTime": ne.Start.Format(time.RFC3339)},
		"end":         map[string]string{"dateTime": ne.End.Format(time.RFC3339)},
	}
	if len(ne.Attendees) > 0 {
		var atts []map[string]string
		for _, a := range ne.Attendees {
			atts = append(atts, map[string]string{"email": a})
		}
		body["attendees"] = atts
	}
	q := url.Values{"sendUpdates": {"all"}}
	if ne.Meet {
		q.Set("conferenceDataVersion", "1")
		body["conferenceData"] = map[string]any{
			"createRequest": map[string]any{
				// requestId is an idempotency token; event identity works fine
				"requestId":             fmt.Sprintf("mlqs-%d", ne.Start.Unix()),
				"conferenceSolutionKey": map[string]string{"type": "hangoutsMeet"},
			},
		}
	}
	var created apiEvent
	if err := c.do(ctx, "POST", "/calendars/"+url.PathEscape(calID)+"/events", q, body, &created); err != nil {
		return nil, err
	}
	ev := flatten(calID, created)
	return &ev, nil
}

var reICSUID = regexp.MustCompile(`(?mi)^UID:(.+)$`)

// ICSUID extracts the UID from raw .ics bytes (unfolds continuation lines).
func ICSUID(ics []byte) string {
	s := strings.ReplaceAll(string(ics), "\r\n ", "")
	s = strings.ReplaceAll(s, "\n ", "")
	if m := reICSUID.FindStringSubmatch(s); m != nil {
		return strings.TrimSpace(m[1])
	}
	return ""
}
