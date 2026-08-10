#!/usr/bin/env bash
# Rigol DS1000Z bench scope (e.g. DS1074Z) over USBTMC.
# READ-ONLY: only SCPI *queries* — never changes scope config, so it is safe to
# run while you are using the scope. Talks straight to the kernel usbtmc char
# device with stdlib python3 (no pyvisa / pyusb).
#
#   ./scope.sh idn                 # identify the instrument (*IDN?)
#   ./scope.sh status              # trigger status once: RUN/WAIT/TD/AUTO/STOP
#   ./scope.sh shot [out.bmp]      # screenshot now (:DISPlay:DATA? -> BMP24)
#   ./scope.sh wait [out.bmp] [n]  # catch n triggers (re-arming); n=0/omitted = until Ctrl-C
#   ./scope.sh wait --single [out.bmp] [n]   # re-arm single-shot via a :SINGle *write*
#   ./scope.sh raw ':SYST:ERR?'    # send an arbitrary SCPI *query* (must end with ?)
#
# 'wait' re-arms between shots: passively (NORM/AUTO self-re-arm, read-only) or,
# with --single, by writing :SINGle each cycle (run-control, not a config change).
# Multi-shot writes are numbered out-1.bmp, out-2.bmp, ...
#
# The char device + its permissions:
#   - node is SCOPE_DEV (dut.env; default /dev/usbtmc0), created by the kernel
#     `usbtmc` driver when it binds the Rigol (lsusb id 1ab1:04ce).
#   - it is root:root 0600 by default -> either run under sudo, or install a
#     udev rule once so your user (plugdev) gets r/w:
#       echo 'SUBSYSTEM=="usbtmc", MODE="0660", GROUP="plugdev"' \
#         | sudo tee /etc/udev/rules.d/60-usbtmc.rules
#       sudo udevadm control --reload && sudo udevadm trigger
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

SCOPE_DEV="${SCOPE_DEV:-/dev/usbtmc0}"

cmd="${1:-idn}"; shift || true

# 'wait' takes an optional --single/-s flag before the positionals.
single=0
if [ "$cmd" = "wait" ] && { [ "${1:-}" = "--single" ] || [ "${1:-}" = "-s" ]; }; then single=1; shift; fi

out="${1:-$RUN_DIR/scope-$(date +%Y%m%d-%H%M%S).bmp}"   # scope emits BMP24
count="${2:-0}"                                          # wait: 0 = loop until Ctrl-C

# selftest exercises the pure helpers without touching hardware; skip the node checks.
if [ "$cmd" != "selftest" ]; then
    [ -e "$SCOPE_DEV" ] || hil_die "no $SCOPE_DEV — scope off, or kernel usbtmc hasn't bound it (lsusb | grep 1ab1)"
    { [ -r "$SCOPE_DEV" ] && [ -w "$SCOPE_DEV" ]; } \
        || hil_die "$SCOPE_DEV not r/w for you — install the udev rule (see header) or run under sudo"
fi

exec python3 - "$SCOPE_DEV" "$cmd" "$out" "$count" "$single" <<'PY'
import os, sys, time, fcntl, struct

dev, cmd, out = sys.argv[1], sys.argv[2], sys.argv[3]
count = int(sys.argv[4])          # 'wait': how many triggers to catch (0 = forever)
single = sys.argv[5] == "1"       # 'wait': re-arm single-shot with a :SINGle write


def armed(s):
    return s in ("WAIT", "RUN", "AUTO")


def fired(s, prev):
    # a trigger fired if the scope reports TD, or edged into STOP from an armed state
    # (single-shot). ponytail: a 20ms poll can miss a very brief TD in fast continuous
    # mode; the STOP edge covers single-shot, which is what re-arm actually cares about.
    return s == "TD" or (s == "STOP" and armed(prev))


def numbered(path, i):
    # i==0 -> single catch, keep the name as-is; else insert -i before the extension.
    if i == 0:
        return path
    root, dot, ext = path.rpartition(".")
    return "%s-%d.%s" % (root, i, ext) if dot else "%s-%d" % (path, i)


if cmd == "selftest":
    assert armed("WAIT") and armed("RUN") and armed("AUTO") and not armed("STOP") and not armed("TD")
    assert fired("TD", "WAIT") and fired("STOP", "RUN")
    assert not fired("STOP", "STOP") and not fired("WAIT", "RUN") and not fired("RUN", "WAIT")
    assert numbered("a.bmp", 0) == "a.bmp"
    assert numbered("a.bmp", 2) == "a-2.bmp"
    assert numbered("a", 3) == "a-3"
    assert numbered("run/scope-x.bmp", 1) == "run/scope-x-1.bmp"
    print("selftest ok")
    sys.exit(0)


def set_timeout(fd, ms):
    # USBTMC_IOCTL_SET_TIMEOUT = _IOW('usbtmc'=91, 10, __u32). The default 5s is
    # too short for a ~1MB :DISP:DATA? screenshot (the scope renders it first).
    SET_TIMEOUT = (1 << 30) | (4 << 16) | (91 << 8) | 10
    try:
        fcntl.ioctl(fd, SET_TIMEOUT, struct.pack("I", ms))
    except OSError as e:
        sys.stderr.write("scope: set-timeout ioctl failed (%s); using kernel default\n" % e)


def ask(fd, s, n=4096):
    os.write(fd, s.encode() + b"\n")
    return os.read(fd, n)


def query_block(fd, s):
    """Read an IEEE-488.2 definite-length block: #<ndigits><len><data>."""
    os.write(fd, s.encode() + b"\n")
    buf = bytearray()

    def pull(need):
        while len(buf) < need:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                raise IOError("short read (%d/%d bytes)" % (len(buf), need))
            buf.extend(chunk)

    pull(2)
    assert buf[0:1] == b"#", "not a block response: %r" % bytes(buf[:16])
    ndig = int(chr(buf[1]))
    pull(2 + ndig)
    length = int(buf[2:2 + ndig])
    pull(2 + ndig + length)
    return bytes(buf[2 + ndig:2 + ndig + length])


def status(fd):
    return ask(fd, ":TRIGger:STATus?").decode().strip()


def syst_err(fd):
    try:
        return ask(fd, ":SYSTem:ERRor?").decode(errors="replace").strip()
    except OSError:
        return "(no reply to :SYST:ERR?)"


def screenshot(fd, path):
    # DS1074Z firmware rejects the 3-arg :DISP:DATA? form (-220 Parameter error); the
    # bare query returns a 24-bit BMP (800x480 -> 1152054 B). Pure framebuffer read,
    # no config change. Convert to PNG afterwards if you want: `convert x.bmp x.png`.
    try:
        img = query_block(fd, ":DISPlay:DATA?")
    except (OSError, IOError, AssertionError) as e:
        raise SystemExit("scope: screenshot failed (%s); error queue: %s" % (e, syst_err(fd)))
    with open(path, "wb") as f:
        f.write(img)
    return len(img)


fd = os.open(dev, os.O_RDWR)
set_timeout(fd, int(os.environ.get("SCOPE_TIMEOUT_MS", "20000")))
try:
    if cmd == "idn":
        print(ask(fd, "*IDN?").decode().strip())
    elif cmd == "status":
        print(status(fd))
    elif cmd == "shot":
        print("wrote %s (%d bytes)" % (out, screenshot(fd, out)))
    elif cmd == "raw":
        q = out  # the SCPI string is passed as the 3rd positional
        if not q.strip().endswith("?"):
            raise SystemExit("scope: 'raw' allows queries only (must end with '?') — stays read-only")
        sys.stdout.write(ask(fd, q, 1 << 16).decode(errors="replace"))
    elif cmd == "wait":
        n = 0
        prev = status(fd)
        sys.stderr.write("waiting for trigger%s (status=%s)... Ctrl-C to stop\n"
                         % (" [single re-arm]" if single else "", prev))
        while True:
            s = status(fd)
            if fired(s, prev):
                n += 1
                path = numbered(out, 0 if count == 1 else n)
                sys.stderr.write("triggered (status=%s) -> shot %d\n" % (s, n))
                print("wrote %s (%d bytes)" % (path, screenshot(fd, path)))
                sys.stdout.flush()
                if count and n >= count:
                    break
                if single:
                    os.write(fd, b":SINGle\n")   # run-control write: re-arm the single-shot
                # wait until the scope reports an armed state again before hunting the
                # next edge, so one trigger can't be counted twice.
                while not armed(status(fd)):
                    time.sleep(0.02)
                prev = "WAIT"
                continue
            prev = s
            time.sleep(0.02)
    else:
        sys.stderr.write("usage: scope.sh {idn|status|shot [out]|wait [--single] [out] [n]|raw '<query>?'}\n")
        sys.exit(2)
except KeyboardInterrupt:
    sys.exit(130)
finally:
    os.close(fd)
PY
