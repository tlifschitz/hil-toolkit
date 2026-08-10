# hil-toolkit

Thin, **non-interactive** wrappers to drive a microcontroller on real hardware
from a shell or a CI job: build, flash, reset, scripted gdb, RTT logs, serial
console, bench scope, power profiler.

Every command starts something detached and returns, or runs one batch and
returns. Nothing waits for a human. That is the whole point: it makes on-target
work scriptable — and lets an agent or a CI runner drive the board the same way
you do.

- **Self-contained.** `probe-rs`, stdlib `python3`, `stty`, `tail`. Only the PPK2
  driver needs `numpy` + `pyserial`.
- **One probe, one owner.** Flash, gdb and RTT all want the same debug probe.
  Long-lived sessions record their pid in `run/probe.pid`; one-shot commands
  refuse while a session holds it, instead of failing deep inside the tool.
- **Logs, not terminals.** Serial and RTT capture to `run/*.log`; you `tail`,
  `watch`, or grep them. Ctrl-C never loses history.
- **One build path.** Anything that flashes runs `build.sh` first, so a stale
  image cannot reach the target.

## Setup

```bash
cp dut.env.example dut.env      # set CHIP, FIRMWARE, HIL_BUILD_CMD, SERIAL_PORT
chmod +x *.sh hil
./doctor.sh                     # preflight: tools, probe, serial, artifacts, instruments
```

`dut.env` is gitignored — device coordinates and any secrets stay out of the
repo. Logs and pidfiles live in `run/` (also gitignored).

Drop the directory into a firmware repo as `hil/` and relative paths in
`dut.env` resolve against the repo root; or keep it standalone and use absolute
paths.

## Commands

`./hil <area> …` or `./<area>.sh …`

### Build — `build.sh`
```bash
./build.sh          # runs $HIL_BUILD_CMD from the project root
```
The single source of truth for the HIL build. The toolkit does not care how you
build, only that `$FIRMWARE` (ELF) and `$FLASH_IMAGE` exist afterwards.

### Flash / reset — `flash.sh`, `reset.sh`
```bash
./flash.sh          # build, then download + reset
./flash.sh fw.elf   # flash this image as-is, skip the build
./reset.sh          # reset and run
```
ELF and hex carry their own load addresses; a raw `.bin` is flashed at
`$FLASH_ADDR` (default `0x0`) — set it for projects with a bootloader.

### Serial console — `serial.sh`
```bash
./serial.sh start           # detached reader: $SERIAL_PORT -> run/serial.log
./serial.sh cmd version     # send a line, then show the fresh output
./serial.sh tail 60 | watch | stop
```
Reader and writer share the tty: a detached `cat` holds it open (keeping the raw
termios `stty` set), while `send` writes `"<line>\r\n"`. Captures boot output too,
if the reader is up before reset.

### RTT logs — `rtt.sh`
```bash
./rtt.sh start      # probe-rs attach -> run/rtt.log (no reflash, no reset)
./rtt.sh tail 60 ; ./rtt.sh watch ; ./rtt.sh stop
```
Needs the ELF to locate the RTT control block. Holds the probe.

### Scripted debug — `gdb.sh` (batch, not single-step)
```bash
./gdb.sh bt                          # halt, backtrace, resume
./gdb.sh inspect SystemCoreClock x   # print expressions
./gdb.sh break my_function           # break, continue until hit, backtrace
./gdb.sh exec -ex "info registers"   # raw passthrough
./gdb.sh server stop
```
Connecting a gdb client halts the core; detaching resumes it. Every batch ends in
`detach` — one that dies early leaves the target halted.

### Bench scope — `scope.sh` (Rigol DS1000Z over USBTMC)
```bash
./scope.sh idn                      # *IDN?
./scope.sh status                   # trigger status: RUN/WAIT/TD/AUTO/STOP
./scope.sh shot capture.bmp         # screenshot now
./scope.sh wait trig.bmp 5          # catch 5 triggers, re-arming between shots
./scope.sh raw ':SYST:ERR?'         # arbitrary SCPI query (must end with '?')
```
Default commands are **read-only** — SCPI queries only, so they never disturb the
scope's configuration while you are using it. Talks straight to the kernel
`usbtmc` char node with stdlib `python3` (no pyvisa/pyusb).

- `wait` polls trigger status and screenshots on each `TD`, then waits for an armed
  state again before hunting the next edge (one trigger ≠ two shots). In NORM/AUTO
  the scope self-re-arms, so the whole loop stays passive. `--single` re-arms a
  SINGLE-mode trigger by *writing* `:SINGle` — run control, not a config change.
- A BMP save takes ~3–5 s, so triggers inside that window are missed. Good for
  occasional events, not back-to-back bursts.
- Screenshot is BMP24 (`:DISPlay:DATA?`, bare form — DS1074Z firmware rejects the
  3-arg `ON,OFF,PNG` variant with `-220 Parameter error`). ~1.15 MB, several
  seconds to render, so the read timeout is 20 s (`SCOPE_TIMEOUT_MS`).

### Power profiler — `ppk.sh` + `ppk2.py` (Nordic PPK2, source-meter mode)
```bash
./ppk.sh info                       # identity + calibration
./ppk.sh avg 10                     # mean/min/max current over 10 s (+ mAh/day)
./ppk.sh measure 60 --avg 100 --power   # 60 s capture -> 1 kHz CSV (t_s,current_uA,logic)
./ppk.sh plot run/ppk-X.csv -o x.png    # offline envelope plot (headless)
./ppk.sh reset                      # recover a wedged PPK2
./ppk.sh selftest                   # pure-math checks, no hardware
```
Self-contained driver: numpy-vectorized, full 100 kSa/s with `lost 0` at ~20 % of
one core.

- **The rail is session-scoped** (instrument-imposed): the PPK2 resets when its
  port closes, so `--power` supplies the DUT only while the session runs. A
  powered experiment is one long `measure <secs> --power` with the events fired
  inside it. Back-to-back sessions are fine — each close costs ~3 s of USB
  re-enumeration, which the wrapper waits out.
- **Never hold DTR across sessions.** Skipping the close-reset wedges the
  instrument's control endpoint; recovery is `ppk.sh reset` (the bulk endpoint
  survives) or a replug.
- CSV columns: `t_s` (device-clocked, 10 µs/sample), `current_uA`, `logic`
  (8-bit logic port, sampled synchronously — wire a firmware event pin to it for
  phase correlation, since the instrument has no hardware trigger).
- **Hours-long runs: use `avg`**, or `measure --avg 10000` for a 10 Hz trace. RAM
  is O(1) either way, but a full-rate CSV grows ~2.4 MB/s (~35 GB / 4 h) and
  `plot` loads the whole file (~30 M rows practical cap).
- Lost samples are detected with the per-sample rolling counter and reported in
  the summary. Range-switch transients are blanked (3 samples, forward-filled),
  mirroring the Nordic app's spike filter.

## Gotchas

- **Do not halt a healthy device casually.** Attaching gdb halts the core. A halt
  landing mid-transfer can lose a peripheral's completion interrupt and wedge a
  driver — you end up debugging the debugger.
- **A blocking log transport will change the timing you are measuring.** RTT
  configured blocking + a lagging or absent reader stalls the firmware inside the
  logging call. Validate timing-sensitive behaviour on a build whose logs are
  cheap, or keep the reader running and expect the perturbation.
- **A serial console under load drops output**, whichever peripheral it shares
  contention with. Space the polls, or read RTT instead.
- The `usbtmc` node is `root:root 0600` by default. Install a udev rule once:
  ```bash
  echo 'SUBSYSTEM=="usbtmc", MODE="0660", GROUP="plugdev"' \
    | sudo tee /etc/udev/rules.d/60-usbtmc.rules
  sudo udevadm control --reload && sudo udevadm trigger
  ```
  probe-rs needs the same treatment for the debug probe — install its rules from
  the probe-rs docs, or every command needs `sudo`.
- **A verified flash is not a running image.** If the target has a bootloader with
  an update slot, it may reinstall a staged image over yours on the next boot.
  Check the boot banner, not the programmer's exit code.
- `plot` is offline by design: it reads any CSV, needs no hardware, and cannot
  stall an automated run.

## Demo target

Any board with a debug probe that probe-rs speaks to. The cheap end:

- **Seeed XIAO nRF54L15** — an onboard SAMD11 bridge exposes CMSIS-DAP v2 and a
  CDC serial port over the single USB-C connector, so flash, gdb, RTT and
  `serial.sh` all work with nothing else attached.
- Any board plus a **Raspberry Pi Debug Probe** (CMSIS-DAP) on the SWD pins.

For power measurement, note that an onboard debug bridge is powered from the same
USB connector as the target. To measure the MCU alone: flash over USB, unplug it,
supply the board from the PPK2, and correlate events through a GPIO wired to the
PPK2 logic port. Check your board's schematic for whether the bridge shares the
target's rail.

## License

MIT — see [LICENSE](LICENSE).

`ppk2.py` is an independent implementation of the PPK2 serial protocol, written
against the public protocol descriptions in Nordic's
[pc-nrfconnect-ppk](https://github.com/NordicSemiconductor/pc-nrfconnect-ppk) and
IRNAS's [ppk2-api-python](https://github.com/IRNAS/ppk2-api-python).
