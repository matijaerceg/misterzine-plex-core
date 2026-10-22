"""The PASS/FAIL scorer the host-side tests share (harvested from UMD's tools/tests/umd_synth.py
at cc595c6: its Score class alone; the rest synthesised UMD disc structures).
"""
import sys


class Score(object):
    """check()/raises() print PASS/FAIL per line; finish() prints the ALL GREEN
    marker run_tests.sh requires positively, and exits non-zero on any failure."""

    def __init__(self, name):
        self.name, self.fails = name, 0

    @staticmethod
    def _short(v):
        r = repr(v)
        return r[:77] + "..." if len(r) > 80 else r

    def check(self, label, got, want):
        ok = got == want
        print("  %s %s: %s%s" % ("PASS" if ok else "FAIL", label, self._short(got),
                                 "" if ok else " want " + self._short(want)))
        self.fails += 0 if ok else 1

    def raises(self, label, fn, exc, frag):
        try:
            fn()
        except exc as e:
            ok = frag in str(e)
            print("  %s %s: raised %s" % ("PASS" if ok else "FAIL", label, e))
            self.fails += 0 if ok else 1
            return
        print("  FAIL %s: did not raise" % label)
        self.fails += 1

    def finish(self):
        import sys
        print("%s: %s" % (self.name, "ALL GREEN" if not self.fails
                          else "%d FAILURE(S)" % self.fails))
        sys.exit(1 if self.fails else 0)
