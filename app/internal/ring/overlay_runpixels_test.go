package ring

import "testing"

// A run moves as fast left as right, at any raster scale, and never stands.
func TestRunPixelsSymmetric(t *testing.T) {
	for _, sx := range []float64{0.5, 0.75, 1, 4.0 / 3, 1.5, 2, 8.0 / 3} {
		for vx := 1; vx <= 3; vx++ {
			r, l := runPixels(vx, sx), runPixels(-vx, sx)
			if r < 1 || l != -r {
				t.Fatalf("scale %v speed %d: right %d, left %d", sx, vx, r, l)
			}
		}
	}
	if runPixels(0, 1) != 0 || runPixels(2, 1) != 2 || runPixels(-2, 1) != -2 {
		t.Fatal("runPixels at 1:1")
	}
}
