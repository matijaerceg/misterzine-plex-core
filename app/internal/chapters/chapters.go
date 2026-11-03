// Package chapters defines scene metadata shared with optional extensions.
package chapters

// Chapter uses source seconds. Image is an opaque server artwork reference.
type Chapter struct {
	Title, Image string
	Start, End   float64
}
