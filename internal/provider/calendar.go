package provider

import (
	"context"
	"time"
)

// Calendar types are vendor-blind like the mail types: Google Calendar and
// Microsoft Graph both flatten into these, and they flow to the UI as-is.

type Calendar struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Primary bool   `json:"primary"`
	Color   string `json:"color"`
	Role    string `json:"role"` // owner|writer|reader|freeBusyReader
}

type CalAttendee struct {
	Email  string `json:"email"`
	Name   string `json:"name"`
	Status string `json:"status"`
	Self   bool   `json:"self"`
}

type CalEvent struct {
	ID        string        `json:"id"`
	CalID     string        `json:"calId"`
	Title     string        `json:"title"`
	Location  string        `json:"location"`
	Start     time.Time     `json:"start"`
	End       time.Time     `json:"end"`
	AllDay    bool          `json:"allDay"`
	MeetLink  string        `json:"meetLink"`
	HTMLLink  string        `json:"htmlLink"`
	MyStatus  string        `json:"myStatus"` // accepted|declined|tentative|needsAction|"" (no attendee entry)
	Organizer string        `json:"organizer"`
	Attendees []CalAttendee `json:"attendees"`
	ICalUID   string        `json:"iCalUid"`
}

type NewEvent struct {
	Title     string
	Location  string
	Start     time.Time
	End       time.Time
	Attendees []string
	Meet      bool
	Notes     string
}

type CalendarProvider interface {
	Calendars(ctx context.Context) ([]Calendar, error)
	Events(ctx context.Context, calID string, from, to time.Time) ([]CalEvent, error)
	RSVP(ctx context.Context, calID, eventID, status string) error
	FindByICalUID(ctx context.Context, calID, uid string) (*CalEvent, error)
	Create(ctx context.Context, calID string, ne NewEvent) (*CalEvent, error)
}
