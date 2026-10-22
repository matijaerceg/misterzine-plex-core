# Acknowledgements

- The **MiSTer** project and its contributors: the framework this core is built on
  (Template_MiSTer, Main_MiSTer).
- **MiSTer_UMD_Video**, the PSP UMD Video player core this core's decoder, display path,
  build gates and process come from, and **MiSTer_DVD**, from which that core came.
- **Moonlight** (moonlight-embedded, moonlight-common-c; Iwan Timmer, Cameron Gutman and
  contributors): the game-streaming client the core's Moonlight support is built on, and
  **Sunshine** (LizardByte), the open host it streams from.
- **Jellyfin** and its clients: the server the core's Jellyfin support plays from;
  **jellyfin-mpv-shim**, the cast-only client whose flow the cast client in `clients/jellyfin`
  follows; and **MiSTerFin**
  (Pudding Studio), the first Jellyfin client for MiSTer, read for ideas (its Quick Connect flow,
  its transcode request) -- none of its code is used.
- **FFmpeg**: its libraries (LGPL) read the containers and decode the sound in the Jellyfin
  cast client and the video player, and decode the older video formats in the player and the
  camera viewer's Motion JPEG; with the ITU-T **JM** reference software it is also the
  decoder's verification oracle.
- **libusb**: the camera viewer's access to USB cameras (LGPL).
- **OpenSSL**, **curl**, **opus**, **expat** and **libevdev**, linked into the Moonlight client
  (and OpenSSL and curl into the Jellyfin cast client).
- **cJSON** (Dave Gamble) in the Jellyfin cast client; **stb_truetype** (Sean Barrett) and the
  **DejaVu** fonts, which draw the on-screen text of the Jellyfin cast client, the video player and
  the camera viewer; and Mozilla's CA certificate list as **curl** publishes it.
- The H.264 FPGA literature the decoder was sized against (Agostini et al.; Petrovsky et
  al.; K. Xu's *nova*, ideas only).

Licensing: GPL-3.0-or-later; see [LICENSE](https://github.com/owenb321/MiSTer_h264_decoder/blob/main/LICENSE) and
[NOTICE](https://github.com/owenb321/MiSTer_h264_decoder/blob/main/NOTICE).
