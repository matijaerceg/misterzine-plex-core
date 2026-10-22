"""Summarize opt-in transition traces against cadence data captured from the screen.

The cadence JSON is a list with one run per transition, oldest first:
[{"shown": [{"seq": S, "field": F}, ...]}, ...], where S is a frame's
publication sequence number (the trace's Published.Published) and F the core's
32-bit field counter when that frame was first on screen.

Run the app with PLEXCRT_TRANSITION_TRACE=1. Extract only 'transition trace {' log
lines, then pass that file and the cadence JSON here. Timings contain no media
titles, server URLs or credentials. The last N traces match N cadence runs.
"""
import collections
import json
import statistics
import sys

samples = json.load(open(sys.argv[2]))
traces = [json.loads(line.split('transition trace ', 1)[1])
          for line in open(sys.argv[1]) if 'transition trace {' in line][-len(samples):]
seen = {f['seq']: f['field'] for run in samples for f in run['shown']}
held = before_publish = fits = unseen = 0
gaps = collections.Counter()
blend, draw = [], []
for t in traces:
    for i in range(1, len(t['BackgroundReady'])):
        blend.append((t['BackgroundReady'][i]['US'] - t['BackgroundBegin'][i]['US']) / 1000)
    for f in t['Frames'][:t['Count']]:
        duration = f['Drawn']['US'] - f['Begin']['US']
        draw.append(duration / 1000)
        p = f['Published']
        if p['Published'] in seen:
            gaps[(seen[p['Published']] - p['Field']) & 0xffffffff] += 1
        else:
            unseen += 1
        if f['Requested'] > f['Chosen']:
            held += 1
            ready = t['BackgroundReady'][f['Requested']]['US']
            before_publish += ready < p['US']
            fits += ready + duration < p['US']
print(json.dumps(dict(
    transitions=len(traces), held_steps=held,
    held_ready_before_publication=before_publish,
    held_ready_plus_original_draw_before_publication=fits,
    publication_to_display_fields=dict(gaps), unobserved_publications=unseen,
    blend_median_ms=round(statistics.median(blend), 3), blend_max_ms=round(max(blend), 3),
    draw_median_ms=round(statistics.median(draw), 3), draw_max_ms=round(max(draw), 3),
), indent=2))
