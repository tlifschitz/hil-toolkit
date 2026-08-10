#!/usr/bin/env python3
"""Nordic PPK2 power profiler driver — source-meter mode.

Self-contained implementation of the PPK2 serial protocol (protocol references:
Nordic pc-nrfconnect-ppk, IRNAS ppk2-api-python). The sample pipeline is
numpy-vectorized, so the full-rate 100 kSa/s stream parses in a few % of one core.

Power semantics (instrument-imposed): the PPK2 resets when its port closes, so
the source rail is only up while a session holds it — there is no fire-and-forget
"power on". avg/measure default to rail-off (measuring floor/noise); pass --power
to supply the DUT at PPK_VOLTAGE_MV for the duration of the session.

Sample frame (uint32 LE): bits 0-13 ADC, 14-16 range, 18-23 rolling counter
(consecutive-sample check -> lost-sample count), 24-31 logic-port state.
"""
import argparse
import os
import queue
import sys
import threading
import time

import numpy as np
import serial

SAMPLE_HZ = 100_000
ADC_MULT = 1.8 / 163840
# Samples held (forward-filled) after a measurement-range switch. The Nordic app
# runs a rolling-average spike filter instead; blanking the same 3-sample window
# kills the same range-switch transients without per-sample Python.
SPIKE_BLANK = 3
VDD_MIN, VDD_MAX = 800, 5000

# serial command opcodes
AVERAGE_START = 0x06
AVERAGE_STOP = 0x07
REGULATOR_SET = 0x0D
DEVICE_RUNNING_SET = 0x0C
SET_POWER_MODE = 0x11  # arg: 1 = ampere meter, 2 = source meter
GET_META_DATA = 0x19
RESET = 0x20


def encode_vdd(mv):
    """REGULATOR_SET payload bytes: (3, 32) is 800 mV, then linear per mV."""
    mv = min(max(mv, VDD_MIN), VDD_MAX)
    diff = mv - VDD_MIN + 32
    return 3 + diff // 256, diff % 256


def parse_metadata(text):
    meta = {}
    for line in text.splitlines():
        key, sep, val = line.partition(": ")
        if sep:
            meta[key.strip()] = val.strip()
    return meta


class SampleParser:
    """Vectorized raw-stream -> µA converter with lost-sample detection and
    range-switch spike blanking. Stateful across chunks (byte remainder, rolling
    counter, blank carry, last good value)."""

    MOD_KEYS = ("R", "GS", "GI", "O", "S", "I", "UG")
    DEFAULTS = {
        "R": [1031.64, 101.65, 10.15, 0.94, 0.043],
        "GS": [1.0] * 5,
        "GI": [1.0] * 5,
        "O": [0.0] * 5,
        "S": [0.0] * 5,
        "I": [0.0] * 5,
        "UG": [1.0] * 5,
    }

    def __init__(self, meta, vdd_mv):
        self.vdd_v = vdd_mv / 1000.0
        for key in self.MOD_KEYS:
            vals = list(self.DEFAULTS[key])
            for rng in range(5):
                raw = meta.get(f"{key}{rng}")
                if raw is None:
                    continue
                # some units report R#: 0 for uncalibrated ranges — keep the default
                # (R divides the ADC result; every other key may legitimately be 0)
                if key == "R" and float(raw) == 0:
                    continue
                vals[rng] = float(raw)
            setattr(self, key, np.array(vals))
        self._rem = b""
        self._prev_cnt = None
        self._prev_rng = None
        self._blank_left = 0
        self._last_good = np.nan

    def parse(self, buf):
        """One chunk of raw bytes -> (current_uA float64[], logic uint8[], lost int, corrupt int).

        The last whole word is withheld until the next chunk: classifying a word
        needs one diff of lookahead (see the corrupt-word check below)."""
        buf = self._rem + buf
        n = len(buf) // 4
        if n < 2:
            self._rem = buf
            return np.empty(0), np.empty(0, np.uint8), 0, 0
        m = n - 1  # words emitted now; word m is withheld
        self._rem = buf[m * 4:]
        raw = np.frombuffer(buf[: n * 4], dtype="<u4")

        adc = (raw & 0x3FFF).astype(np.float64) * 4.0
        rng = np.minimum((raw >> 14) & 0x7, 4).astype(np.intp)
        cnt = ((raw >> 18) & 0x3F).astype(np.int64)
        logic = ((raw >> 24) & 0xFF).astype(np.uint8)[:m]

        rwg = (adc - self.O[rng]) * (ADC_MULT / self.R[rng])
        ua = (self.UG[rng] * (
            rwg * (self.GS[rng] * rwg + self.GI[rng]) + (self.S[rng] * self.vdd_v + self.I[rng])
        ) * 1e6)[:m]

        # The 6-bit counter increments by 1 per sample. A mismatch is either a
        # CORRUPT word — glitched during a range switch, counter bit-flipped, the
        # chain resumes immediately, so its two surrounding diffs sum to 2 mod 64
        # (bench-proven signature, and what Nordic's app treats as corruption) —
        # or a genuine gap of (diff-1) LOST samples. Corrupt words also carry a
        # suspect ADC value, so they join the blank/forward-fill mask below.
        prev_cnt = self._prev_cnt if self._prev_cnt is not None else int(cnt[0]) - 1
        d = np.diff(cnt, prepend=prev_cnt) & 0x3F
        bad_d = d != 1
        corrupt_mask = bad_d[:m] & bad_d[1: m + 1] & (((d[:m] + d[1: m + 1]) & 0x3F) == 2)
        ci = np.flatnonzero(corrupt_mask)
        explained = np.zeros(n, bool)
        explained[ci] = True
        explained[ci + 1] = True
        sel = bad_d[:m] & ~explained[:m]
        lost = int(np.sum((d[:m][sel] - 1) & 0x3F))
        corrupt = int(ci.size)
        if corrupt_mask[m - 1]:
            # last emitted word is corrupt: its counter is garbage; synthesize the
            # true value so the withheld word's diff next chunk stays clean
            self._prev_cnt = int((cnt[m - 2] if m >= 2 else prev_cnt + 1) + 1) & 0x3F
        else:
            self._prev_cnt = int(cnt[m - 1])

        # blank SPIKE_BLANK samples from each range switch (+ corrupt words), then forward-fill
        prev_rng = self._prev_rng if self._prev_rng is not None else int(rng[0])
        switches = np.flatnonzero(np.diff(rng[:m], prepend=prev_rng) != 0)
        self._prev_rng = int(rng[m - 1])
        bad = np.zeros(m, bool)
        if self._blank_left:
            bad[: self._blank_left] = True
        for i in switches:  # range switches are rare; python loop is cheap
            bad[i: i + SPIKE_BLANK] = True
        bad[ci] = True
        spill = self._blank_left - m
        if switches.size:
            spill = max(spill, int(switches[-1]) + SPIKE_BLANK - m)
        self._blank_left = max(0, spill)

        if bad.any():
            src = np.where(~bad, np.arange(m), -1)
            np.maximum.accumulate(src, out=src)
            ua = np.where(src >= 0, ua[np.maximum(src, 0)], self._last_good)
        self._last_good = ua[-1]
        return ua, logic, lost, corrupt


class Stats:
    def __init__(self):
        self.n = 0
        self.total = 0.0
        self.mn = np.inf
        self.mx = -np.inf
        self.lost = 0
        self.corrupt = 0

    def add(self, ua, lost, corrupt):
        good = ua[~np.isnan(ua)]
        self.lost += lost
        self.corrupt += corrupt
        if good.size == 0:
            return
        self.n += good.size
        self.total += float(good.sum())
        self.mn = min(self.mn, float(good.min()))
        self.mx = max(self.mx, float(good.max()))

    def report(self, vdd_mv):
        if self.n == 0:
            return "no samples"
        mean = self.total / self.n
        return (
            f"samples {self.n} ({self.n / SAMPLE_HZ:.2f} s @ {SAMPLE_HZ // 1000} kSa/s)  "
            f"lost {self.lost}  corrupt {self.corrupt}\n"
            f"mean {mean:.3f} uA   min {self.mn:.3f}   max {self.mx:.3f}\n"
            f"~ {mean * 24 / 1000:.3f} mAh/day @ {vdd_mv / 1000:.2f} V"
        )


class CsvSink:
    """CSV writer: t_s,current_uA,logic. group>1 averages current over N samples
    and ORs the logic byte (so short pulses survive downsampling)."""

    def __init__(self, path, group):
        self.f = open(path, "w", buffering=1 << 20)
        self.f.write("t_s,current_uA,logic\n")
        self.group = group
        self.abs = 0  # full-rate index of first pending sample
        self.ua = np.empty(0)
        self.lg = np.empty(0, np.uint8)
        self.rows = 0

    def add(self, ua, lg):
        self.ua = np.concatenate((self.ua, ua))
        self.lg = np.concatenate((self.lg, lg))
        self._flush(partial=False)

    def _flush(self, partial):
        g = self.group
        k = len(self.ua) // g * g
        if partial and k < len(self.ua):
            k = len(self.ua)  # final short group
        if k == 0:
            return
        pad = (-k) % g
        ua = np.pad(self.ua[:k], (0, pad), constant_values=np.nan) if pad else self.ua[:k]
        lg = np.pad(self.lg[:k], (0, pad)) if pad else self.lg[:k]
        t = (self.abs + np.arange(0, k + pad, g)) / SAMPLE_HZ
        with np.errstate(invalid="ignore"):
            cur = np.nanmean(ua.reshape(-1, g), axis=1)
        bits = np.bitwise_or.reduce(lg.reshape(-1, g), axis=1)
        np.savetxt(self.f, np.column_stack((t, cur, bits)), fmt="%.5f,%.3f,%d")
        self.rows += len(t)
        self.abs += k
        self.ua = self.ua[k:]
        self.lg = self.lg[k:]

    def close(self):
        self._flush(partial=True)
        self.f.close()


class Ppk2:
    """One PPK2 session. The device resets itself when the port closes (DTR
    drop) — instrument semantics, same as closing the Nordic app: the source
    rail drops and the device re-enumerates (~3 s; ppk.sh waits for the node).
    Keeping DTR up across sessions instead wedges the firmware hard (control
    endpoint dead, only RESET/replug recovers), so every session is
    self-contained and the rail is only up while a --power session holds it."""

    def __init__(self, port):
        # a stale node can pass the wrapper's existence check and still vanish
        # before open (udev tearing down the previous enumeration) — retry
        deadline = time.monotonic() + 8
        while True:
            try:
                self.ser = serial.Serial(port, baudrate=9600, timeout=0.5, write_timeout=1,
                                         exclusive=True)
                break
            except (OSError, serial.SerialException):
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.5)

    def cmd(self, *b):
        self.ser.write(bytes(b))

    def read_metadata(self):
        self.cmd(AVERAGE_STOP)  # metadata parses cleanly only with the stream stopped
        time.sleep(0.2)
        self.ser.reset_input_buffer()
        self.cmd(GET_META_DATA)
        buf = b""
        deadline = time.monotonic() + 3
        while b"END" not in buf and time.monotonic() < deadline:
            buf += self.ser.read(4096)
        if b"END" not in buf:
            sys.exit("ppk2: no metadata reply — wrong port, or another process holds the PPK2")
        return parse_metadata(buf.decode(errors="replace"))

    def prepare(self, mv, power):
        """Source-meter mode + regulator target (required before streaming),
        optionally raising the DUT rail for the lifetime of this session."""
        self.cmd(SET_POWER_MODE, 2)
        self.cmd(REGULATOR_SET, *encode_vdd(mv))
        if power:
            self.cmd(DEVICE_RUNNING_SET, 1)


class Drain(threading.Thread):
    """Reader thread: keeps the CDC-ACM buffer drained no matter what the main
    loop is doing (CSV flush, GC); chunks land in an unbounded queue."""

    def __init__(self, ser):
        super().__init__(daemon=True)
        self.ser = ser
        self.q = queue.Queue()
        self.stop_evt = threading.Event()

    def run(self):
        # Poll every ~1 ms and keep the kernel tty buffer near-empty: letting it
        # fill (batched 50 ms reads) engages the cdc_acm throttle path, which on
        # this 5.4 kernel wedges the PPK2 stream for good. Chunks are coalesced
        # to ~50 ms before queueing so downstream numpy calls stay large.
        local = b""
        last_put = time.monotonic()
        while not self.stop_evt.is_set():
            data = self.ser.read(self.ser.in_waiting or 1)
            if data:
                local += data
            now = time.monotonic()
            if local and now - last_put >= 0.05:
                self.q.put(local)
                local = b""
                last_put = now
            time.sleep(0.001)
        if local:
            self.q.put(local)


def stream(ppk, parser, secs, sink):
    stats = Stats()
    stalled = False
    drain = Drain(ppk.ser)
    ppk.ser.reset_input_buffer()
    ppk.cmd(AVERAGE_START)
    drain.start()
    deadline = time.monotonic() + secs
    last_data = time.monotonic()
    try:
        while time.monotonic() < deadline:
            try:
                bufs = [drain.q.get(timeout=0.05)]
            except queue.Empty:
                if time.monotonic() - last_data > 2.0:
                    stalled = True
                    break
                continue
            last_data = time.monotonic()
            while True:
                try:
                    bufs.append(drain.q.get_nowait())
                except queue.Empty:
                    break
            ua, logic, lost, corrupt = parser.parse(b"".join(bufs))
            stats.add(ua, lost, corrupt)
            if sink:
                sink.add(ua, logic)
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
    finally:
        ppk.cmd(AVERAGE_STOP)
        # Slurp the device-side residue before closing: closing the port with
        # samples still in flight wedges the PPK2's CDC endpoint until a RESET.
        # The drain thread keeps reading; wait for the line to go quiet.
        quiet = 0
        give_up = time.monotonic() + 1.5
        while quiet < 3 and time.monotonic() < give_up:
            time.sleep(0.05)
            quiet = quiet + 1 if ppk.ser.in_waiting == 0 else 0
        drain.stop_evt.set()
        drain.join()
        if sink:
            sink.close()
    return stats, stalled


def envelope(a, buckets):
    """Peak-detect decimation: per-bucket (min, max, mean) — a bucket max cannot
    miss a spike, unlike subsampling or plain averaging. Returns (bucket_size,
    mins, maxes, means); the tail short of a full bucket is dropped."""
    n = max(1, len(a) // buckets)
    k = len(a) // n * n
    r = a[:k].reshape(-1, n)
    return n, r.min(axis=1), r.max(axis=1), r.mean(axis=1)


PLOT_BUCKETS = 8000  # ~4x a screen width; zooming re-decimates from raw


def do_plot(path, out):
    if out:
        import matplotlib
        matplotlib.use("Agg")
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ppk2: matplotlib missing under this interpreter — pip install matplotlib")

    data = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
    t, ua = data[:, 0], data[:, 1]
    logic = data[:, 2].astype(np.uint16)
    active_bits = [b for b in range(8) if np.any(logic & (1 << b)) and not np.all(logic & (1 << b))]

    if active_bits:
        fig, (ax, axl) = plt.subplots(2, 1, sharex=True, figsize=(12, 7),
                                      height_ratios=[3, 1], layout="constrained")
    else:
        fig, ax = plt.subplots(figsize=(12, 5), layout="constrained")
        axl = None

    mean = float(np.nanmean(ua))
    fig.suptitle(f"{os.path.basename(path)} — {len(ua)} rows, {t[-1] - t[0]:.2f} s   "
                 f"mean {mean:.2f} uA  min {np.nanmin(ua):.2f}  max {np.nanmax(ua):.2f}"
                 f"  (~{mean * 24 / 1000:.2f} mAh/day)", fontsize=10)
    from matplotlib.ticker import SymmetricalLogLocator
    ax.set_yscale("symlog", linthresh=1.0)
    ax.yaxis.set_minor_locator(SymmetricalLogLocator(base=10, linthresh=1.0, subs=range(2, 10)))
    ax.set_ylabel("current [uA]")
    ax.grid(True, which="major", alpha=0.3)
    ax.grid(True, which="minor", alpha=0.12)
    (ax if axl is None else axl).set_xlabel("t [s]")
    if axl is not None:
        axl.set_yticks([b + 0.4 for b in active_bits], [f"D{b}" for b in active_bits])
        axl.set_ylim(-0.2, active_bits[-1] + 1)

    band = [None]
    # the max edge as its own hairline: a lone spike is a sub-pixel band sliver
    # that fill_between rasterizes away
    max_ln, = ax.plot([], [], lw=0.4, color="C0", alpha=0.6)
    mean_ln, = ax.plot([], [], lw=0.8, color="C0")
    lanes = {b: axl.plot([], [], lw=0.8, drawstyle="steps-post", color="C2")[0]
             for b in (active_bits if axl is not None else [])}

    def render(lo, hi):
        i0, i1 = np.searchsorted(t, [lo, hi])
        i0, i1 = max(0, i0 - 1), min(len(t), i1 + 1)
        seg_t, seg = t[i0:i1], ua[i0:i1]
        if len(seg) < 2:
            return
        n, mn, mx, av = envelope(seg, PLOT_BUCKETS)
        bt = seg_t[: len(av) * n: n]
        if band[0] is not None:
            band[0].remove()
        band[0] = ax.fill_between(bt, mn, mx, alpha=0.35, color="C0", lw=0)
        max_ln.set_data(bt, mx)
        mean_ln.set_data(bt, av)
        for b, ln in lanes.items():
            lane = (logic[i0:i1] >> b) & 1
            _, _, lmx, _ = envelope(lane, PLOT_BUCKETS)
            ln.set_data(bt, lmx[: len(bt)] * 0.8 + b)

    render(t[0], t[-1])
    ax.set_xlim(t[0], t[-1])
    # autoscale tracks only the mean line, clipping the envelope's peaks — span the raw data
    ax.set_ylim(min(float(np.nanmin(ua)), 0.0), float(np.nanmax(ua)) * 2)

    if out:
        fig.savefig(out, dpi=110)
        print(f"wrote {out}")
        return

    guard = [False]

    def on_xlim(a):
        if guard[0]:
            return
        guard[0] = True
        render(*a.get_xlim())
        fig.canvas.draw_idle()
        guard[0] = False

    ax.callbacks.connect("xlim_changed", on_xlim)
    plt.show()


def selftest():
    def frame(adc, rng, cnt, logic=0):
        return (adc | rng << 14 | cnt << 18 | logic << 24).to_bytes(4, "little")

    assert encode_vdd(800) == (3, 32)
    assert encode_vdd(100) == (3, 32)  # clamped to VDD_MIN
    assert encode_vdd(3300) == (12, 228)
    assert encode_vdd(5000) == (19, 136)

    # conversion: R=1000, unity gains -> ua = adc*4 * ADC_MULT/1000 * 1e6
    # (the last word of each parse is withheld for lookahead: n frames -> n-1 samples)
    meta = {f"R{i}": "1000" for i in range(5)}
    meta.update({f"GS{i}": "0" for i in range(5)})
    p = SampleParser(meta, 3300)
    ua, logic, lost, corrupt = p.parse(frame(1000, 0, 0, logic=0xA5) + frame(1000, 0, 1))
    assert len(ua) == 1 and abs(ua[0] - 1000 * 4 * ADC_MULT / 1000 * 1e6) < 1e-9, ua
    assert logic[0] == 0xA5 and lost == 0 and corrupt == 0

    # lost samples across split chunks + byte remainder
    p = SampleParser(meta, 3300)
    buf = frame(1, 0, 0) + frame(1, 0, 1) + frame(1, 0, 5) + frame(1, 0, 6) + frame(1, 0, 7)
    r1 = p.parse(buf[:6])
    r2 = p.parse(buf[6:])
    assert r1[2] + r2[2] == 3 and r1[3] + r2[3] == 0, (r1[2:], r2[2:])
    # counter wrap 63 -> 0 is not a loss
    p = SampleParser(meta, 3300)
    _, _, lost, corrupt = p.parse(frame(1, 0, 63) + frame(1, 0, 0) + frame(1, 0, 1))
    assert lost == 0 and corrupt == 0

    # corrupt word: counter bit-flipped mid-chain (0,1,2^8,3,4) -> corrupt=1, no
    # loss, and its (garbage) value is replaced by the previous good sample
    p = SampleParser(meta, 3300)
    ua, _, lost, corrupt = p.parse(
        frame(1000, 0, 0) + frame(1000, 0, 1) + frame(3333, 0, (2 ^ 8)) +
        frame(1000, 0, 3) + frame(1000, 0, 4) + frame(1000, 0, 5))
    assert lost == 0 and corrupt == 1, (lost, corrupt)
    assert ua[2] == ua[1], ua

    # envelope decimation: a single-sample spike must survive; tail dropped
    a = np.zeros(1000)
    a[500] = 42.0
    n, mn, mx, av = envelope(a, 10)
    assert n == 100 and len(mx) == 10, (n, len(mx))
    assert mx[5] == 42.0 and mn[5] == 0.0 and abs(av[5] - 0.42) < 1e-12
    n, _, mx, _ = envelope(np.arange(7.0), 3)
    assert n == 2 and list(mx) == [1.0, 3.0, 5.0]  # 7th sample dropped

    # spike blanking: 3 samples after the range switch hold the last good value
    p = SampleParser(meta, 3300)
    ua, _, _, _ = p.parse(b"".join(frame(1000, 0, i) for i in range(2)) +
                          b"".join(frame(3000, 1, 2 + i) for i in range(6)))
    assert ua[1] == ua[2] == ua[3] == ua[4], ua  # switch at idx 2 blanks 2,3,4
    assert ua[5] == ua[6] != ua[1], ua

    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", default="")
    ap.add_argument("--mv", type=int, default=3300)
    ap.add_argument("--run-dir", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    sub.add_parser("info")
    sub.add_parser("reset")
    s = sub.add_parser("avg")
    s.add_argument("secs", type=float, nargs="?", default=5.0)
    s.add_argument("--power", action="store_true",
                   help="raise the DUT rail for the duration of this session")
    s = sub.add_parser("measure")
    s.add_argument("secs", type=float)
    s.add_argument("-o", "--out")
    s.add_argument("--avg", type=int, default=1, metavar="N",
                   help="downsample: mean current / OR'd logic over N samples per row")
    s.add_argument("--power", action="store_true",
                   help="raise the DUT rail for the duration of this session")
    s.add_argument("--plot", action="store_true",
                   help="open an interactive plot of the capture when it ends")
    s = sub.add_parser("plot")
    s.add_argument("csv")
    s.add_argument("-o", "--out", help="render to PNG instead of an interactive window")
    args = ap.parse_args()

    if args.cmd == "selftest":
        selftest()
        return
    if args.cmd == "plot":
        do_plot(args.csv, args.out)
        return

    ppk = Ppk2(args.port)
    if args.cmd == "reset":
        ppk.cmd(RESET)
        print("PPK2 reset — re-enumerating (~3 s)")
        return

    meta = ppk.read_metadata()
    if args.cmd == "info":
        print(f"PPK2 {args.port}  HW {meta.get('HW', '?')}  calibrated={meta.get('Calibrated', '?')}  "
              f"vdd(config)={args.mv} mV")
        for key in SampleParser.MOD_KEYS:
            vals = [meta.get(f"{key}{i}", "-") for i in range(5)]
            print(f"  {key}: {' '.join(vals)}")
        return

    parser = SampleParser(meta, args.mv)
    ppk.prepare(args.mv, args.power)
    if args.power:
        print(f"DUT rail ON @ {args.mv} mV for this session (drops at exit)", file=sys.stderr)
    if args.cmd == "avg":
        stats, stalled = stream(ppk, parser, args.secs, None)
        print(stats.report(args.mv))
    elif args.cmd == "measure":
        out = args.out or os.path.join(args.run_dir, time.strftime("ppk-%Y%m%d-%H%M%S.csv"))
        sink = CsvSink(out, max(1, args.avg))
        stats, stalled = stream(ppk, parser, args.secs, sink)
        print(f"wrote {out} ({sink.rows} rows"
              + (f", {args.avg} samples/row" if args.avg > 1 else "") + ")")
        print(stats.report(args.mv))
    if args.power:
        ppk.cmd(DEVICE_RUNNING_SET, 0)  # deterministic rail-drop before the close-reset
    if stalled:
        sys.exit("ppk2: stream stalled (device wedged) — recover with 'hil/ppk.sh reset' "
                 "(NOTE: reset drops the DUT rail)")
    if args.cmd == "measure" and args.plot:
        ppk.ser.close()  # release the device before the (arbitrarily long) viewing
        do_plot(out, None)


if __name__ == "__main__":
    main()
