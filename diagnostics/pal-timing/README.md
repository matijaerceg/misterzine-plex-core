# PAL timing diagnostic 1

This optional worker records why a 25 fps video might select 480i60 instead of
576i50. It requires Plex beta31 and adds a separate Scripts launcher. It does
not replace the installed app, worker, core, updater or saved access.

Installation instructions and verified downloads accompany the diagnostic
download. Exit Plex before starting the diagnostic launcher.

1. Run **Scripts > MisterZine-Plex-PAL-Diagnostic**.
2. In the core OSD set **Output Mode: 576i50** and **Refresh Rate Match: 50/60**.
3. Start the affected video with subtitles off and let it play for ten seconds.
4. If it selects the wrong output, note what Playback Info shows. Stop playback
   and immediately use **Options > Send a report**. Share its report code.
5. Exit the app. The normal MisterZine Plex launcher still runs the original
   installed worker. To remove the extra launcher, run:

```sh
python3 /media/fat/misterzine-plex/diagnostics/pal-timing-1/install.py remove
```

The existing report contains numeric video rates, selected/effective display
modes, decoder flags and bounded H.264 SPS/PPS headers. Headers describe video
format and timing; picture slices, audio samples and SEI payloads are excluded.
The diagnostic does not enable URL logging. Report redaction remains active.

This is an investigation build, not a playback fix or a regular release.
