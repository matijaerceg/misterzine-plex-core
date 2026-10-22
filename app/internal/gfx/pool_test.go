package gfx

import "testing"

func TestDarkenScalesEveryByte(t *testing.T) {
	c := NewCanvas(37, 3) // a width that leaves a tail after the four-pixel steps
	for i := range c.Pix {
		c.Pix[i] = byte(i * 7)
	}
	orig := append([]byte(nil), c.Pix...)
	c.Darken(56)
	for i, v := range orig {
		want := byte(int(v) * 56 >> 8)
		if c.Pix[i] != want {
			t.Fatalf("byte %d: got %d want %d", i, c.Pix[i], want)
		}
		// the old scalar copy divided by 255: never more than a level apart
		if old := byte(int(v) * 56 / 255); old-c.Pix[i] > 1 {
			t.Fatalf("byte %d: %d is more than a level below %d", i, c.Pix[i], old)
		}
	}
}

func TestSpareCanvasesComeBackBySize(t *testing.T) {
	a := TakeCanvas(30, 20)
	GiveCanvas(a)
	GiveCanvas(a) // twice: still held once
	if b := TakeCanvas(31, 20); b == a {
		t.Fatal("a spare of another size was handed out")
	}
	if b := TakeCanvas(30, 20); b != a {
		t.Fatal("the spare was not reused")
	}
	if b := TakeCanvas(30, 20); b == a {
		t.Fatal("a canvas given once was handed out twice")
	}
	for i := 0; i < maxSpares+3; i++ {
		GiveCanvas(NewCanvas(2, 2))
	}
	spareMu.Lock()
	n := len(spares)
	spareMu.Unlock()
	if n > maxSpares {
		t.Fatalf("%d spares kept, at most %d", n, maxSpares)
	}
}
