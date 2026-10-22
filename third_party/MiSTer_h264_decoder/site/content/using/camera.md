# Showing a USB camera

The core comes with a viewer for a USB webcam or a USB video capture device plugged into the
MiSTer. It shows the camera's picture on HDMI and on the analog output, a CRT included, so the
MiSTer can act as a 15 kHz screen for another source.

!!! warning "Webcams that send Motion JPEG, at DVD size"
    The MiSTer's ARM processor decodes the camera's pictures, so the viewer shows them up to
    720x576 at up to 30 frames per second. Most webcams send Motion JPEG (MJPEG), which works.
    The MiSTer's USB port carries only about 6 MB/s of live video, so cameras and capture
    devices that send only uncompressed video work at small sizes only (320x240 at 30 frames
    per second, for example). See [Compatibility](../reference/compatibility.md#usb-cameras).

There is no sound: the viewer shows the picture only.

## Installing

MisterZine Jellyfin releases do not include the viewer: build it and copy its
`Scripts/h264cam.sh` and `h264cam/` folder to the root of the SD card (`/media/fat/`), with
the core in `_Other/` ([The other programs](../getting-started/install.md#the-other-programs)).

## Showing a camera

Run **Scripts** → **h264cam** from the MiSTer menu. The core loads and asks you to plug in a
camera; if one is plugged in already, its picture appears straight away. The viewer picks the
camera's largest Motion JPEG mode up to 720x576 at 30 frames per second, and says which.

| Gamepad | Keyboard | |
|---|---|---|
| A, Start | Space, Enter | pause: the picture stays still; press again for the live picture |
| B | I | the list of the camera's modes (or the OSD's **Program menu**) |
| Back + Start | Q | quit to the MiSTer menu |

In the list of modes:

| Gamepad | Keyboard | |
|---|---|---|
| Up / Down | Up / Down | move |
| LB / RB | Page Up / Page Down | a page up / down |
| A, Start, Right | Enter, Space, Right | show the camera in that mode |
| B, Left | Esc, Backspace, Left | back to the picture |
| Back + Start | Q | quit to the MiSTer menu |

The list shows only the modes the viewer can show. The one in use is marked `>`.

**Program menu** in the MiSTer menu opens the list of modes (or closes it); **Send Home to the
program** quits the viewer ([Settings](settings.md)).

If you unplug the camera, the screen goes black and the viewer waits for one again: plug it
back in, or another camera.

In a dark room, a webcam may lower its frame rate to let in more light. The viewer asks it to
keep its full frame rate, so the picture can be darker than on a computer. Add light rather than
expecting the camera to.

## When a camera cannot be shown

The viewer says **cannot be shown** and why, and waits until you unplug it:

| Message | Meaning |
|---|---|
| "it sends only uncompressed video, which needs more USB bandwidth than the MiSTer's port carries at these sizes" | A capture device or camera without Motion JPEG, with no mode small enough. |
| "its video is H.264 only, not MJPEG or uncompressed" | A camera that sends only H.264. |
| "none of its modes fits: 720 x 576 at most, 30 frames a second at most" | Every mode is larger or faster than the ARM can decode. |
| "its pictures could not be decoded" | The camera's pictures are in a form the viewer does not read. |

[Troubleshooting](../reference/troubleshooting.md#usb-cameras) has more.

## The screensaver

While no camera is shown, the viewer dims the screen after 5 minutes and turns it black after
30, as the [video player](player.md#the-screensaver) does. Any button brings it back.
