# On-screen messages

| What you see | Meaning |
|---|---|
| A black screen before the app menu appears | The core is waiting for the app to draw its first screen. |
| A black screen after a video played | The program feeding the core switched streams, sought, or is starting the next stream: the core shows black until the next picture. If it stays black, the program has stopped sending video. |
| The last picture of a video, still | The stream ended; the core keeps its last picture on screen until the program sends another. |

The core draws no other messages. Programs feeding it can read its state (playing, ended,
errors) from its status block, and draw their own screens over the picture: the
[video player](player.md)'s list and its **Cannot play** messages (see
[Troubleshooting](../reference/troubleshooting.md#video-files)), the
menus and playback controls of [MisterZine Jellyfin](jellyfin.md), the
[camera viewer](camera.md)'s **Plug in a USB camera** screen, its list of modes and its
**cannot be shown** messages (see [Troubleshooting](../reference/troubleshooting.md#usb-cameras)).
