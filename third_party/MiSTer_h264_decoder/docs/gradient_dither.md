# Gradient dithering

Gradient Dither in the core menu defaults to On. On distributes the final RGB
rounding error across a stable 16 by 16 pixel pattern. This can soften banding
without adding a constant color offset. It cannot remove encoded compression
artifacts or recover precision already lost in earlier scaling stages.

This is separate from the removed analog DAC dither. It acts before the overlay
and before RGB is converted to component or composite, and affects both HDMI and
analog video. Menus and blanking are not dithered. All three RGB channels use the
same threshold, so neutral input remains neutral. Output clipping is unchanged.
The pattern follows full-frame raster coordinates, with one threshold per logical
pixel for two-dot modes. It does not invert between fields. The OSD level crosses
two synchronizer registers and is selected at the next frame origin.

Status bit 30 disables the option when set; zero selects On. Off retains the original +128 fixed rounding.
On substitutes every integer threshold from 0 through 255 once in each 16 by 16
tile. For a constant Q8 value, the tile average is exactly its clipped ideal value.
This is an average guarantee for constant input, not for arbitrary varying images.
The decoder, compressed stream and output timing are unchanged.

Run `bash bench/h264/run_rgb_dither.sh` for rank, mean, Off behavior, pipeline
alignment, clock-enable hold, neutral-gray, clipping and blanking checks. Run the
existing display-reader regression with the new input tied low to check Off.
Hardware evaluation must include dark and colored ramps, interlaced playback,
OSD toggling and both output paths; fitting/timing qualification is also required.
