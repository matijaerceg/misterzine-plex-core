# Loading the core

The core is normally **loaded by the program that feeds it**: the program starts the core
the way MiSTer's own shortcuts (`.mgl` files) do, then starts sending video. This build is
loaded by MisterZine Plex: its **MisterZine Plex** entry in the main menu loads the core and
starts the app. The core file is kept in the app's release folder, not in `_Other/`.

The screen stays black until the program draws its first screen. See
[On-screen messages](../using/on-screen-messages.md).

The core has **no file browser entry** and loads no files through the OSD: it accepts no
file types. Video reaches it only from a program, such as the four that come with it
([What you need](what-you-need.md)). To play a video file, run the
[video player](../using/player.md) from the **Scripts** menu.
