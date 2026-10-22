package ui

import (
	"encoding/json"
	"os"
	"time"
)

var traceTransitions = os.Getenv("PLEXCRT_TRANSITION_TRACE") == "1"

type transitionTracePoint struct {
	US                      int64
	Field, Published, Shown uint32
}

type transitionTraceFrame struct {
	Requested, Ready, Chosen int
	Begin, Drawn, Published  transitionTracePoint
}

type transitionTrace struct {
	start           time.Time
	status          func() (uint32, uint32, uint32)
	BackgroundBegin [transitionSteps]transitionTracePoint
	BackgroundReady [transitionSteps]transitionTracePoint
	Frames          [64]transitionTraceFrame
	Count           int
	Episodes        bool
}

func (t *transitionTrace) point() transitionTracePoint {
	f, p, s := t.status()
	return transitionTracePoint{time.Since(t.start).Microseconds(), f, p, s}
}

func (v *Show) traceStart() {
	v.trace = nil
	if !traceTransitions {
		return
	}
	if out, ok := v.app.Out.(interface {
		TraceStatus() (uint32, uint32, uint32)
	}); ok {
		v.trace = &transitionTrace{start: time.Now(), status: out.TraceStatus, Episodes: v.episodes}
	}
	v.fade.trace = v.trace
}

func (v *Show) traceDrawn() {
	if t := v.trace; t != nil && t.Count < len(t.Frames) {
		t.Frames[t.Count].Drawn = t.point()
	}
}

func (v *Show) tracePublished() {
	if t := v.trace; t != nil {
		if t.Count < len(t.Frames) {
			t.Frames[t.Count].Published = t.point()
			t.Count++
		}
		if !v.pacedTransition() {
			v.fade.wg.Wait() // read worker-owned timestamps only after completion
			data, _ := json.Marshal(t)
			v.app.Log.Printf("transition trace %s", data)
			v.trace, v.fade.trace = nil, nil
		}
	}
}
