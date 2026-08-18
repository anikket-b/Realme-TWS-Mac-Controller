# Realme TWS Mac Controller

A macOS menu bar app for **realme / OPPO / OnePlus earbuds** that speak the OPOv1 control
protocol. Shows per-earbud and case battery, switches between ANC / Off / Transparency with
the three ANC strengths, and connects or disconnects the buds — none of which macOS exposes
on its own.

Developed against realme Buds T500 Pro. The buds are found by looking for the paired device
that advertises the control service, so no address is baked into the source and any earbuds
speaking this protocol should work; the mode *values*, though, were confirmed on the T500
Pro only and other models may number them differently (see [The protocol](#the-protocol)).

There is no macOS realme Link. To a Mac these are a plain A2DP/HFP headset: noise control
can only be changed by touching an earbud, and the system reports a single battery figure
instead of three. This app talks to the earbuds' vendor control protocol directly.

(The code, binary, and bundle identifier keep the original internal name **BudsBar** — the
identifier is fixed so the granted Bluetooth permission survives rebuilds.)

State is read back from the earbuds rather than assumed, so the panel and realme Link on a
phone agree with each other. Change the mode on the phone and the app follows within about
a second; change it in the app and the phone follows.

## Install

[![Download](https://img.shields.io/badge/Download-Realme%20TWS%20Mac%20Controller-blue?style=for-the-badge&logo=apple)](https://github.com/aniket-2308/Realme-TWS-Mac-Controller/releases/latest/download/Realme-TWS-Mac-Controller.zip)

Or paste this into Terminal — it downloads the latest release, installs it into
`/Applications`, and launches it:

```sh
curl -fsSL https://raw.githubusercontent.com/aniket-2308/Realme-TWS-Mac-Controller/main/install.sh | sh
```

The build is ad-hoc signed, not notarised. The script clears the quarantine flag for you;
if you download the zip by hand instead, macOS will refuse to open it until you run:

```sh
xattr -dr com.apple.quarantine "/Applications/Realme TWS Mac Controller.app"
```

The download needs no toolchain — the [requirements](#requirements) below apply to building
from source.

## Requirements

- macOS 26 or later (uses the Liquid Glass APIs)
- Swift 6.2+ toolchain — Command Line Tools are enough to compile
- An installed `Xcode.app`, for one file only: the SwiftUI macro plugin. It does **not**
  need to be selected with `xcode-select`. See [Building](#building).
- Earbuds already paired with the Mac and advertising the `oppointeraction` service

## Building

```sh
./build.sh            # release; pass `debug` for a debug build
open "Realme TWS Mac Controller.app"
```

Run the binary directly to see its log on stderr:

```sh
"./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
```

Environment variables, all optional:

| Variable | Effect |
|---|---|
| `BUDSBAR_TRACE=1` | Hex-dump every frame received. Off by default — the buds push status every few seconds. |
| `BUDSBAR_TEST=1` | Command every mode and ANC level in turn and log what the buds report back. |
| `BUDSBAR_ADDRESS=aa-bb-…` | Force a specific device instead of auto-discovering, for when several paired devices speak the protocol. |

`build.sh` compiles with SwiftPM, assembles the `.app` bundle, and ad-hoc signs it. The
bundle identifier is fixed across rebuilds so the granted Bluetooth permission survives,
though re-signing may prompt once more.

### Why Xcode is needed to build

SwiftUI's `@State` and `@Bindable` are macros, and the Command Line Tools ship the SwiftUI
framework *without* its macro plugin — so every property wrapper fails to compile. The
manifest locates `libSwiftUIMacros.dylib` inside any `/Applications/Xcode*.app` and passes
it to the compiler. The plugin loads into the CLT compiler even when that Xcode's own
toolchain is too old to run on the current OS. Declaring it in `Package.swift` rather than
only in `build.sh` keeps SourceKit — and therefore editor diagnostics — working too.

## Layout

```
Package.swift          SwiftPM manifest; also locates the SwiftUI macro plugin
build.sh               build → .app bundle → ad-hoc codesign
Resources/Info.plist   LSUIElement, NSBluetoothAlwaysUsageDescription
Sources/BudsBar/
  App.swift            NSStatusItem menu bar item and the popover that hosts the panel
  Buds.swift           IOBluetooth transport and observable device state
  Protocol.swift       OPOv1 frame encoding/decoding (pure, self-checking)
  PanelView.swift      the panel UI
Tools/sniff.swift      read-only RFCOMM logger, for decoding further settings
```

`Info.plist` needs `NSBluetoothAlwaysUsageDescription`; without it the Bluetooth
permission prompt never appears and RFCOMM fails silently. `LSUIElement` keeps the app out
of the Dock.

## The protocol

The buds expose several RFCOMM services over Bluetooth Classic. The one that matters is
`oppointeraction`, SDP UUID `0000079A-D102-11E1-9B23-00025B00A5A5` — **OPOv1**, the control
protocol shared across BBK Electronics brands (OPPO, OnePlus, realme). The app resolves the
channel by UUID at runtime rather than hardcoding a number, so a firmware renumber can't
silently point it at a different service.

### Frame format

```
aa  <len>  00 00  <cat>  <sub>  <seq>  <payload len: u16le>  <payload…>
```

`len` counts every byte after itself, so a frame is `len + 2` bytes. There is **no
checksum** — the length fields account for the payload exactly. A reply echoes the request's
`seq` and sets the high bit on `sub` (`0x04` → `0x84`). Payload byte 0 of a reply is a
status: `00` accepted, `01` rejected.

### Commands used

| Purpose | Frame |
|---|---|
| Hello | `aa 07 00 00 00 01 <seq> 00 00` |
| Off | `aa 0a 00 00 04 04 <seq> 03 00 01 01 01` |
| Transparency | `aa 0a 00 00 04 04 <seq> 03 00 01 01 02` |
| ANC, Mild | `aa 0a 00 00 04 04 <seq> 03 00 01 01 04` |
| ANC, Max | `aa 0a 00 00 04 04 <seq> 03 00 01 01 08` |
| ANC, Moderate | `aa 0a 00 00 04 04 <seq> 03 00 01 01 10` |

**The ANC and Off values are the reverse of the published OnePlus mapping.** On the T500
Pro `0x01` is Off. Taking the documented mapping at face value produced an app where those
two buttons did each other's job.

**There is no single "ANC" value — the strength is the mode byte.** realme Link's four
noise-cancellation sub-modes each get their own value, and they are not in strength order:

| Value | Mode |
|---|---|
| `01` | Off |
| `02` | Transparency |
| `04` | ANC, Mild |
| `08` | ANC, Max |
| `10` | ANC, Moderate |
| `20` | ANC, Smart |

Confirmed by running `Tools/sniff.swift` while tapping each level on the phone, with
single-tap runs for Mild and Max on their own to break the ambiguity — a multi-tap trace is
hard to read, because the buds also announce their *current* mode when the phone's app
opens, so the first event in a run belongs to the state before it, not to the first tap.

This is also why the earlier reading of `0x08` as "a second ANC variant (adaptive)" was
wrong, and why the ANC button used to command `0x04`: it was pinning the buds to Mild every
time. Smart (`0x20`) is decoded as ANC but deliberately has no level in this app; while it
is active the buds emit a second `03` block — count `4`, one pair — carrying the level Smart
has settled on, which the app ignores so the panel cannot show a level the phone is not.

### Notifications

The buds push status on category `04`, subcommand `02`, unprompted. The payload is a tagged
list — `<type> <count>` then `count` (id, value) pairs:

| Type | Meaning |
|---|---|
| `01` | Battery: id 1 = left, 2 = right, 3 = case, values in percent |
| `02` | Some other setting. Moves when the mode changes but is **not** the mode. Not decoded. |
| `03` | Noise mode: id 1, value as in the table above. Count is always 1 — a `03` block with count 4 is Smart reporting the level it picked, not a mode change. |

Three traps worth knowing, all of which cost real debugging time here:

- The mode lives in the **`03`** block, not `02`. The `02` block also moves when the mode
  changes, which makes it look like the mode until you command a value and watch which
  field actually follows.
- Rejection error codes are **not** a signal about your payload. The same bytes return
  different codes depending on position in a run of requests, so they cannot be used to
  hill-climb toward a correct payload shape.
- Do not trust another device's value mapping. The frame *format* carried over from the
  OnePlus documentation intact, but the ANC and Off values did not.

## Decoding more settings

`Tools/sniff.swift` opens a channel read-only and hex-dumps everything, for working out
opcodes that aren't decoded yet (EQ, touch controls):

```sh
swift Tools/sniff.swift 15        # defaults to 12 15 17
```

macOS hands out one RFCOMM channel per device, so **quit the app before running it** — they
cannot both hold a channel. For the same reason the sniffer takes one channel at a time;
requesting several at once silently returns the same channel repeatedly.

The buds also advertise a `BESOTA` service on channel 13. That is the Bestechnic firmware
OTA endpoint, and a malformed write there can brick the earbuds. `sniff.swift` refuses that
channel outright, and nothing in this project opens it.

## Verifying changes

`Protocol.swift` carries a `selfCheck()` that replays real captured frames — battery, each
mode, a coalesced pair, a frame split across two reads, and leading garbage — and runs
automatically at launch in debug builds:

```sh
./build.sh debug && "./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
# BudsProtocol.selfCheck passed
```

To exercise the radio end to end, `BUDSBAR_TEST=1` commands every ANC level and every mode
in turn and logs what the buds report back. The buds echo the state they actually reached,
so a `LEVEL reported` line matching the command above it is a real confirmation, not just a
successful write:

```sh
BUDSBAR_TEST=1 "./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
# TEST commanding ANC Mild, value 4
# LEVEL reported Mild
```

It leaves the buds switched Off when it finishes.

## Credits

The OPOv1 command layout came from
[Cracking OPOv1](https://aasheesh.vercel.app/blog/oneplus-buds) and
[AasheeshLikePanner/cracked-oneplus-buds](https://github.com/AasheeshLikePanner/cracked-oneplus-buds),
which document the protocol for OnePlus Buds over BLE. The frame format carries over intact
to realme hardware on RFCOMM; the notification payload types here were decoded against the
T500 Pro directly.
