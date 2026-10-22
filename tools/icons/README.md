# Playback bar icons

The Icons playback theme draws its bar buttons from Lucide icons
(https://github.com/lucide-icons/lucide, tag `1.61.0`, ISC License). The SVG
sources, their `LICENSE` and the generated masks live together in
`app/internal/ui/icons/`; the app embeds only the PNG masks and tints them with
the button colour at run time.

Regenerate the masks after changing an SVG or a size:

    cd tools/icons
    go run .

The generator uses only the Go standard library. It draws each icon as Lucide
specifies (round caps and joins) with strokes 2 output pixels wide at the size
listed in `main.go`, samples every pixel 8x8, crops the result to its ink and
writes an 8-bit greyscale PNG. The same sources always give identical bytes.

Sizes: the bar glyphs are 21 pixels to the 24-unit grid, the Body font's height
(25) less 4. The jump arrows (`rotate-ccw`, `rotate-cw`) are 12, so the arrow
and a Body-font "10" fit the narrow `-10` cell. `TestIconMasksFitTheBar` checks
both against the fonts.

To add or update an icon, fetch it from a tagged release, for example

    curl -fLO https://raw.githubusercontent.com/lucide-icons/lucide/1.61.0/icons/play.svg

into `app/internal/ui/icons/`, list it in `main.go` and in `iconFiles` in
`app/internal/ui/icons.go`, and run the generator.
