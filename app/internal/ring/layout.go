package ring

// The H.264 decoder core's HPS interface, version 1.x, as vendored in
// third_party/MiSTer_h264_decoder: hps/include/h264ring_layout.h (generated;
// the word numbers and bit positions below are copied from it) and
// site/content/integrating/{interface,overlay,launch}.md. The control block
// is 64-bit words; every value this package reads or writes is a 32-bit
// half, accessed with one aligned 32-bit load or store (the mapping is
// strongly ordered: anything else can fault on ARMv7).
const (
	ctrlByte  = 0x31400000 // H264RING_CTRL_BYTE: the control block (4 KB)
	ctrlLen   = 0x1000
	ringByte  = 0x31800000 // H264RING_RING_BYTE: the ring (only the player maps it)
	ringSize  = 0x800000
	fbByte    = 0x22000000         // H264RING_FB_BYTE: MiSTer_fb's region, where the overlay's pages lie
	fbSize    = 0x800000           // H264RING_FB_SIZE
	coreMagic = 0x343632485453694D // "MiSTH264", word 0
	ifMajor   = 1                  // H264RING_VERSION 0x101: same major, minor >= 1
	ifMinor   = 1

	wMagic     = 0
	wVersion   = 1  // [15:0] major<<8|minor
	wGeometry  = 2  // [63:32] the ring's size
	wSeqHead   = 3  // [31:0] the heartbeat, +1 a frame; read LAST
	wState     = 4  // [7:0] state, [15:8] error, [23:16] live flags, [31:24] OSD settings
	wAck       = 5  // [63:32] the acknowledged nonce, [31:0] the read index
	wFetch     = 13 // [31:0] fetch_changes: shown pictures fetched by the display
	wFit       = 30 // [45] fit_valid: a picture is shown
	wSeqTail   = 31 // the heartbeat again: read FIRST
	wWriteIdx  = 32 // program: the write index
	wNonce     = 33 // program: the session nonce
	wPause     = 34 // program: [0] pause, [15:8] attenuation
	wSettings  = 35 // program: the settings request (0 = none)
	wRumble    = 36 // program: 36..38, the pads' rumble
	wOvlStat   = 46 // [31:0] ovl_gen, [33:32] state, [39:36] err, [47:40] torn
	wAspect    = 47 // [11:0] ar_x, [23:12] ar_y, [63:32] ovl_lines
	wInput     = 48 // the input region, 48..71
	inWords    = 24
	wOvl       = 72 // the overlay's descriptor, 72..79
	wOvlGenLo  = 72 // written LAST
	wOvlCtl    = 73 // [0] enable, [2:1] format
	wOvlBase   = 74
	wOvlSize   = 75 // [15:0] width, [31:16] height
	wOvlStride = 76
	wOvlBand   = 77 // [15:0] first line, [31:16] last line
	wOvlRsvd   = 78
	wOvlGenHi  = 79 // written FIRST
	wRaster    = 80 // [11:0] raster_w, [23:12] raster_h, [25:24] mode, [26] lb, [28:27] video_out
	wDisplay   = 87 // [2:0] display profile, [3] match refresh, [4] 240p, [5] film speed, [6] wide shape, [10:7] effective profile

	stateNoSession = 1
	stateReady     = 2
	statePlaying   = 3
	stateEnded     = 4
	stateError     = 5

	// live flags (word 4 [23:16])
	LiveLowLatency = 1 << 0
	LiveEOS        = 1 << 1
	LiveEnded      = 1 << 2
	LiveSTCRun     = 1 << 3
	LivePlayed     = 1 << 4
	LiveOSDOpen    = 1 << 5
	LiveSession    = 1 << 6
	LiveGraphics   = 1 << 7

	ovlEnable   = 1 << 0
	ovlFmtLSB   = 1
	FmtARGB1555 = 0
	FmtARGB4444 = 1
	FmtARGB8888 = 2
	ovlMaxSide  = 2048

	OvlOff      = 0
	OvlAccepted = 1
	OvlRefused  = 2
)
