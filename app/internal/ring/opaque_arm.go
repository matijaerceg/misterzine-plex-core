package ring

// opaqueWords is in opaque_arm.s.
//
//go:noescape
func opaqueWords(dst, src *uint32, n int)

// copyOpaque copies src into the start of dst with alpha 255, in blocks of
// eight words (see opaque_arm.s).
func copyOpaque(dst, src []uint32) {
	if len(src) == 0 {
		return
	}
	_ = dst[len(src)-1]
	opaqueWords(&dst[0], &src[0], len(src))
}
