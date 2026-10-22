package ui

// Crop chooses how much of a wide picture is cropped to fill the analog raster.
type Crop string

const (
	CropOff  Crop = "off"
	Crop14x9 Crop = "14:9"
	CropFill Crop = "fill"
)

// Crops are the playback crop choices.
var Crops = []struct {
	Mode  Crop
	Label string
}{{CropOff, "Off"}, {Crop14x9, "14:9"}, {CropFill, "Fill"}}

func (c Crop) index() int {
	for i, x := range Crops {
		if x.Mode == c {
			return i
		}
	}
	return 0
}

func (c Crop) Label() string { return Crops[c.index()].Label }

func (c Crop) valid() Crop { return Crops[c.index()].Mode }

// analogAspect maps the UI choices to the worker's aspect modes. Mode 4 is
// custom geometry and is translated to the core's Letterbox enum in jfplay.
func (c Crop) analogAspect() int {
	switch c.valid() {
	case CropFill:
		return 3
	case Crop14x9:
		// 4 is a jfplay-only geometry mode, never a core menu value.
		return 4
	}
	return 2
}

// VideoCrop is the crop of the playback under way, read at each start.
func (a *App) VideoCrop() Crop { return a.crop }

// setCrop changes the crop until this playback ends.
func (a *App) setCrop(c Crop) { a.crop = c.valid() }
