# Audio

Audio travels through the same ring as video, with its own presentation times, and the
core plays it against the same clock it shows pictures by, so the two stay in sync
without your program having to measure anything. The core plays audio itself rather than
through Linux's sound system for exactly this reason.

## What you send

**Your program decodes the audio** -- any codec its libraries support -- and hands the core
**PCM: 48 kHz, 16-bit signed little-endian, stereo, interleaved** (left, right, left,
right...). Resample and downmix on the ARM first (one call to libswresample or speexdsp; a
few percent of one core). The FPGA does not decode audio codecs: that keeps every codec
your program can decode playable.

Each **AUDIO record** carries whole stereo frames: its length is a multiple of 4 bytes and
not 0 (anything else stops the session with error 6). Give a record the presentation time
of its **first** frame (90 kHz, the same clock as your video's) with PTS_VALID; a record
without one continues from the one before it. The library's
`h264ring_write_audio(r, pcm, len, pts, timeout_ms)` writes one.

- **Send records of 5 ms or more** (240 frames): Opus and AAC frames are 10 to 21 ms, so
  one decoded frame per record is right. The core keeps at most **256 records** it has not
  yet played; past that it waits before reading further into the ring, and the video
  behind them waits too.
- **Keep the audio within about a second of the video you have written.** Audio a few
  hundred milliseconds ahead of the video it goes with is normal, and the order a demuxer
  gives you is usually right. But 256 records of 20 ms are only 5.12 s. Some sources put their
  audio further ahead than that in the stream (a server's live transcode after a seek has been
  seen 6 s ahead). If you write them in that order, the core stops reading with the video
  behind that audio still unread, and that video arrives late: by how far the audio leads past
  those 5.12 s (a 6 s lead alone leaves it under a second late). A 1.1 core keeps playing (below),
  but the picture is then behind the sound for as long as the audio stays that far ahead, and a
  1.0 core could stop the picture altogether. So hold such audio back: write an AUDIO
  record only when its time is at most about one second past the newest video access unit you
  have written. Let the audio through when no more video is coming (the stream's end, or a
  stretch with no video).

## How the core plays it

**Your records stay in the ring until they are played.** The core notes where each AUDIO
record is, fetches its samples a few milliseconds before they play, and holds the **read
index** (word 5) at the start of the oldest audio record it has not fetched yet. So the
read index can lag behind the video you wrote while audio waits to play -- that is the
audio's buffer, and nothing about writing changes: keep `write_index - read_index` within
the ring's size, as always (the library does).

**A stream without LOW_LATENCY** (a film, a transcode) is **paced**:

- Audio starts when the presentation clock reaches its first frame's time. The clock is
  started by the first picture shown -- or, when there is no picture to start it (audio
  only, or audio written far ahead of its video), by the audio itself: at once when 256
  records are waiting, otherwise after one second. The first picture is then shown against
  that running clock.
- Every record with a presentation time is checked when its first frame is due: **more than
  10 ms early** (a gap in your audio), silence plays until it is due; **more than 10 ms
  late** (an overlap, or audio that arrived after its time), its late frames are dropped.
  Within 10 ms it plays on seamlessly, so timestamps rounded to the millisecond (Matroska)
  never cause either.
- If the audio runs dry, silence plays and the next record's time sets the phase again.
- **A late picture and the clock (1.1).** A picture more than 2.7 s late normally moves the
  clock back to it, so that picture and sound line up again after a stall. **Except while the
  queued audio is ahead of the clock**: it waited for its time (or started the clock) and has
  neither run dry nor arrived late since. Then the audio is right and the picture is what is
  late, so the picture is shown at once, late, and counted in `disp_late`, and the clock runs on.
  (On a 1.0 core, moving the clock back behind waiting audio could stop the picture for good:
  the audio, early again, kept the core from reading the video behind it.)

**A stream with LOW_LATENCY** (a game stream) is played as it arrives: the core starts when
it has 20 ms of audio queued and then keeps the queue's low point between 2.5 and 20 ms by
dropping or repeating a single frame at a time (inaudible; at most one in 1,024), which
absorbs the difference between the sender's clock and the core's. More than 250 ms queued
at once (a network stall delivering its backlog) is dropped down to 20 ms. Audio then
trails the picture by roughly 10 to 40 ms, inside what viewers perceive as in sync. The
mode is the stream's, taken from its first access unit's LOW_LATENCY flag; audio sent
before the first access unit is paced.

**Everything is counted** in the status block (words 40-45, see
[The interface](interface.md#the-control-block)): the audio's state, the queue, frames
played, silence played for gaps, frames dropped late, underruns, the low-latency drops and
repeats, how often the audio started the clock, and the difference between the clock and
the last timed record (the A/V offset).

## Pause and volume

Word 34 carries a **pause** and a **volume**, read by the core within a few milliseconds --
not after the seconds of video queued in the ring:

- **PAUSE** freezes everything together: the clock stops, the picture holds, the audio goes
  silent at the frame it reached, and the core stops reading the ring. Clearing it
  continues exactly where it stopped. `h264ring_set_pause(r, 1)` / `(r, 0)`.
- **ATTEN** lowers the audio in 0.5 dB steps: 0 is full volume, 12 is half (-6 dB), 255 is
  mute. `h264ring_set_atten(r, n)`. MiSTer's own volume control still applies on top.

Both apply during your session. The library writes them again at every session start, so a
program that stopped while paused never leaves the next one paused.

## What to expect

- The audio's end counts as one underrun (the queue ran dry): that is normal.
- MiSTer's **audio filter** (its system menu) applies to this core like any other.
- At a DISCONTINUITY the audio queued ahead of it is dropped with the video's queue. Send
  END_OF_STREAM on the last access unit first and the core lets the queued audio finish
  before the next stream starts.
