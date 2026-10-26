package ui
import (
 "testing"
 "time"
 "plexcrt/internal/input"
 "plexcrt/internal/plex"
)
func TestMainMenuWrapKeepsSelectionVisible(t *testing.T) {
 for _, n := range []int{0,1,DrawerRows+4} {
  d := &Drawer{items:make([]*plex.Item,n)}
  d.Key(input.Event{Key:input.Up},time.Now())
  if n>0 && (d.cur!=n-1 || d.cur<d.first || d.cur>=d.first+DrawerRows) { t.Fatalf("wrapped last row not visible: %+v", d) }
  d.Key(input.Event{Key:input.Down},time.Now())
  if d.cur!=0 || d.first!=0 { t.Fatal("wrap to first must restore top") }
 }
}
