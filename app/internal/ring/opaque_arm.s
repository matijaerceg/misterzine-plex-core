#include "textflag.h"

// opaqueWords copies n BGRx pixels from src to dst with the top (alpha)
// byte set to 0xFF: the publish copy into a framebuffer page. The page is
// an uncached mapping, where one word a store costs far more than the
// copy's arithmetic, so the loop moves eight words at a time with LDM/STM
// (each 32-byte block reaches memory as one burst) and preloads the source
// 256 bytes ahead, since a frame does not fit in the cache. A word loop
// does the last n%8. dst and src are word aligned.
//
// func opaqueWords(dst, src *uint32, n int)
TEXT ·opaqueWords(SB), NOSPLIT|NOFRAME, $0-12
	MOVW	dst+0(FP), R0
	MOVW	src+4(FP), R1
	MOVW	n+8(FP), R12
	BIC	$7, R12
	ADD	R12<<2, R1, R12 // end of the whole blocks
	CMP	R12, R1
	BHS	tail

block:
	PLD	256(R1)
	MOVM.IA.W	(R1), [R2-R9]
	ORR	$0xFF000000, R2
	ORR	$0xFF000000, R3
	ORR	$0xFF000000, R4
	ORR	$0xFF000000, R5
	ORR	$0xFF000000, R6
	ORR	$0xFF000000, R7
	ORR	$0xFF000000, R8
	ORR	$0xFF000000, R9
	MOVM.IA.W	[R2-R9], (R0)
	CMP	R12, R1
	BLO	block

tail:
	MOVW	n+8(FP), R12
	AND.S	$7, R12
	BEQ	done

word:
	MOVW.P	4(R1), R2
	ORR	$0xFF000000, R2
	MOVW.P	R2, 4(R0)
	SUB.S	$1, R12
	BNE	word

done:
	RET
