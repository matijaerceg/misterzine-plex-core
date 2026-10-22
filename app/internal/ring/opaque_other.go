//go:build !arm

package ring

// copyOpaque copies src into the start of dst with alpha 255.
func copyOpaque(dst, src []uint32) {
	dst = dst[:len(src)]
	for i, p := range src {
		dst[i] = p | 0xFF000000
	}
}
