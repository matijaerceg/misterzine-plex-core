# MiSTer H264

An **H.264 video decoder for the MiSTer FPGA**, built as a core that programs running on
the MiSTer's ARM side can feed. A game-streaming client, a media-server client or a file
player hands the core compressed video and audio; the FPGA decodes it and shows it on
HDMI or an analog display, in sync. The ARM chip cannot decode H.264 at these rates in
software; this core does it in the FPGA fabric instead.

This is MisterZine Jellyfin's fork of the core, and this manual describes it. The fork is
released only inside MisterZine Jellyfin, which installs and updates it.

!!! warning "A proof of concept, not supported"
    Everything this manual describes runs on real hardware, but the project is offered as it
    is: no help with setups, no fixes on request, no promised features. You are encouraged to
    fork it and take it wherever you like. On its own the core shows a test pattern; a program
    on the MiSTer's ARM side plays through it. See [Compatibility](reference/compatibility.md)
    for what works.

## Who this manual is for

- **If you want to watch something**, start with [Install the core](getting-started/install.md)
  and [What you need](getting-started/what-you-need.md): the core does nothing on its own,
  you need a program that uses it. This build ships with MisterZine Jellyfin
  ([Watching from a Jellyfin server](using/jellyfin.md)); the repository also holds three
  programs you build yourself: [Streaming from a PC (Moonlight)](using/moonlight.md),
  [Playing video files](using/player.md) and [Showing a USB camera](using/camera.md).
- **If you are writing such a program**, read
  [Integrating a program](integrating/overview.md).
