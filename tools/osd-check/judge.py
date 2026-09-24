#!/usr/bin/env python3
"""judge.py: read SurfaceProbe output (run.sh) and check it.

  judge.py keepout <out.txt>        the keep-out script, see run.sh
  judge.py switch <out.txt>...      paused track switches, one per file
  judge.py compare <a.txt> <b.txt>  same OSD at every step of the script

Each step is an ACTION line with the "wait" actions after it and what the
VO posted meanwhile; the OSD "state" after a step is the last buffer posted
(or the one before, if the step posted none): its opaque pixel count and
bounding box (inclusive).
"""
import re
import sys

POST = re.compile(r"^OSD post \d+ at [\d.]+ (\d+)x(\d+) opaque=(\d+) (?:bbox=(\d+),(\d+)-(\d+),(\d+)|empty)")
ACTION = re.compile(r"^ACTION (\S+) at [\d.]+")


def steps(path):
    """[(action, state)], state = None (nothing posted yet) or
    (opaque, x0, y0, x1, y1, h)."""
    out, state, cur = [], None, None
    for line in open(path, errors="replace"):
        m = ACTION.match(line)
        if m:
            if m.group(1).startswith("wait=") and cur is not None and not cur.startswith("wait="):
                continue
            if cur is not None:
                out.append((cur, state))
            cur = m.group(1)
            continue
        m = POST.match(line)
        if m:
            w, h, op = int(m.group(1)), int(m.group(2)), int(m.group(3))
            state = (op, 0, 0, 0, 0, h) if op == 0 else (op, *map(int, m.group(4, 5, 6, 7)), h)
    if cur is not None:
        out.append((cur, state))
    return out


def fmt(st):
    if st is None:
        return "nothing posted"
    return "empty" if st[0] == 0 else "opaque=%d bbox=%d,%d-%d,%d" % st[:5]


def keepout(path):
    fails = 0
    base = {}          # sid -> state with the band down
    sid, k, paused = "start", 0.0, True
    for i, (a, st) in enumerate(steps(path)):
        what, ok = None, True
        m = re.match(r"set=(sub-keepout|vo-mediacodec-osd-sub-keepout)=([\d.]+)$", a)
        if a.startswith("set=sid="):
            sid = a.split("=", 2)[2]
            what, ok = "a subtitle after the switch", bool(st and st[0])
            if ok and k == 0:
                base[sid] = st
        elif a.startswith("set=pause="):
            paused = a.endswith("=yes")
            if not paused:
                base.pop(sid, None)   # another subtitle may be up after playing
        elif m:
            k = float(m.group(2))
            b = base.get(sid)
            if paused and k == 0 and b is None and st and st[0]:
                base[sid] = st
                what = "keep-out 0 after playing (new reference)"
            elif paused and b and st:
                h = st[5]
                limit = h - int(h * k / 100 + 0.5)
                if k == 0:
                    what, ok = "keep-out 0 restores the picture", st == b
                elif b[4] < limit:
                    what, ok = "a subtitle above the band stays", st == b
                else:
                    what = "keep-out %g: below row %d, moved not changed" % (k, limit)
                    ok = (st[4] < limit and st[2] >= 0 and st[0] == b[0] and st[1] == b[1]
                          and st[3] == b[3] and st[4] - st[2] == b[4] - b[2])
        elif a.startswith("wait=") and sid == "start" and "start" not in base and st and st[0]:
            base["start"] = st
        if what:
            print("  %s %-44s %s" % ("PASS" if ok else "FAIL", what, fmt(st)))
            fails += not ok
    return fails


def switch(paths):
    finals = []
    for p in paths:
        st = None
        for a, s in steps(p):
            if a.startswith("set=sid="):
                st = s
        finals.append(st)
    counts = {}
    for st in finals:
        counts[fmt(st)] = counts.get(fmt(st), 0) + 1
    for s, n in sorted(counts.items(), key=lambda x: -x[1]):
        print("  %3d x %s" % (n, s))
    good = [st for st in finals if st and st[0]]
    ok = len(good) == len(finals) and len(counts) == 1
    print("  %s %d runs, every one ending on the same subtitle" % ("PASS" if ok else "FAIL", len(finals)))
    return 0 if ok else 1


def compare(a, b):
    # the same script under either option name
    alias = lambda act: act.replace("vo-mediacodec-osd-sub-keepout", "sub-keepout")
    sa = [(alias(x), st) for x, st in steps(a)]
    sb = [(alias(x), st) for x, st in steps(b)]
    fails = 0
    if [x for x, _ in sa] != [x for x, _ in sb]:
        print("  FAIL different scripts")
        return 1
    for (act, x), (_, y) in zip(sa, sb):
        if x != y:
            print("  DIFF %-40s %s | %s" % (act, fmt(x), fmt(y)))
            fails += 1
    print("  %s %d steps compared" % ("PASS" if not fails else "FAIL", len(sa)))
    return fails


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    n = {"keepout": lambda: keepout(args[0]), "switch": lambda: switch(args),
         "compare": lambda: compare(*args)}[mode]()
    sys.exit(1 if n else 0)
