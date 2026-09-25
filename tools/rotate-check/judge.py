#!/usr/bin/env python3
"""judge.py <out.txt> <expect>: check one RotateProbe run (run.sh).

  expect: none         no message about a rotation filter at all: the VO
                       rotates (VO_CAP_ROTATE90)
          fatal        lavfi's `rotate` filter was asked for and is not in
                       the build ("filter 'rotate' not found or failed to
                       allocate"): the VO in the chain cannot rotate (vo=null)
          unsupported  the frames cannot be rotated in software at all
                       ("Video rotation with this format not supported":
                       MediaCodec surface frames), no filter asked for

Every "MARK <layout>" has to follow a frame of that layout (the last VIDEO
line before it), and the run has to end with rc 0.
"""
import re
import sys

VIDEO = re.compile(r"^VIDEO frame \d+ at ([\d.]+) \d+x\d+ layout=(\S+)")
MARK = re.compile(r"^MARK (\S+) at ([\d.]+)")
LOG = re.compile(r"^\s+[\d.]+ \[([^\]]+)\] (.*)")
FILTER_MSGS = {
    "fatal": "filter 'rotate' not found or failed to allocate",
    "inserting": "Inserting rotation filter.",
    "could-not": "could not create rotation filter",
    "unsupported": "Video rotation with this format not supported",
}


def main():
    path, expect = sys.argv[1], sys.argv[2]
    frames, fails, seen, rc = [], [], {}, None
    for line in open(path, errors="replace"):
        m = VIDEO.match(line)
        if m:
            frames.append((float(m.group(1)), m.group(2)))
            continue
        m = MARK.match(line)
        if m:
            want, t = m.group(1), float(m.group(2))
            before = [lay for (ft, lay) in frames if ft < t]
            got = before[-1] if before else "no frame"
            print(f"  mark {want}: {got} {'ok' if got == want else 'FAIL'}")
            if got != want:
                fails.append(f"expected {want} at {t:.3f}, the last frame was {got}")
            continue
        m = LOG.match(line)
        if m:
            for k, text in FILTER_MSGS.items():
                if text in m.group(2):
                    seen.setdefault(k, []).append(f"[{m.group(1)}] {m.group(2).strip()}")
            continue
        if line.startswith("EXIT rc="):
            rc = int(line.split("=", 1)[1])
    for k, lines in seen.items():
        print(f"  {k}: {len(lines)}x {lines[0]}")
    if expect == "none" and seen:
        fails.append("rotation filter messages where the VO rotates: " + ", ".join(seen))
    elif expect == "fatal" and ("fatal" not in seen or "inserting" in seen):
        fails.append(f"expected the missing-filter message, got {sorted(seen) or 'none'}")
    elif expect == "unsupported" and ("unsupported" not in seen or "fatal" in seen or "inserting" in seen):
        fails.append(f"expected only 'not supported', got {sorted(seen) or 'none'}")
    if rc != 0:
        fails.append(f"exit rc {rc}")
    for f in fails:
        print("  FAIL " + f)
    print(f"  {'PASS' if not fails else 'FAIL'} ({expect})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
