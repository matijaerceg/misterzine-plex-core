# Controls

The core does nothing with your controls itself. It **passes them on** to the program that feeds
it, such as the [Moonlight client](moonlight.md), which sends them to your PC, or the
[MisterZine Jellyfin](jellyfin.md) and the [video player](player.md), which use them to pause, seek
and choose what to play, and the [camera viewer](camera.md), which uses them to pause and choose a mode. MiSTer's menu keeps
working as usual: the menu button, or F12 on a keyboard, opens the core's OSD.

## Gamepads

The core offers four controller roles in MiSTer's **Define H264 buttons** mapping:

| Role | Default position |
|---|---|
| OK | Right face button |
| Back | Bottom face button |
| Page Back | Left shoulder |
| Page Forward | Right shoulder |

The D-pad always moves up, down, left or right. The two shoulder roles are optional shortcuts;
the program can use them to move between pages. Up to six pads are supported, numbered by MiSTer
the way it numbers players.

MiSTer assigns these roles by position the first time. You can change any assignment in the OSD's
system settings if your controller behaves differently, or skip an optional page shortcut; MiSTer
remembers the mapping for this core.

The Guide / Home button opens MiSTer's own menu.

## Keyboard and mouse

Every key MiSTer gives a core is passed on, and so are the mouse's movement, its wheel and five
buttons (left, right, middle, back and forward). MiSTer keeps some keys for itself; they never
reach the core:

- F12, which opens the menu
- the Menu key
- Win+PrintScreen and Alt+ScrollLock, which take screenshots
- the volume and mute keys
- NumLock and ScrollLock, which switch MiSTer's keyboard-as-joystick modes

## While the menu is open

MiSTer sends nothing to the core while its menu is open. A program forwarding your controls
releases every key, button and stick on the PC when the menu opens, so nothing stays held down
there. Controls resume when the menu closes.
