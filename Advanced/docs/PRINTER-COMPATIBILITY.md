# Printer Compatibility

FlipStack is a macOS 13+ print manager built on CUPS. It prints through CUPS
queues with `/usr/bin/lp`, reads queue state with `/usr/bin/lpstat`, and reads
printer capabilities from PPD files. It does not contain vendor drivers and it
does not bypass CUPS.

This document describes what FlipStack can detect, what it can control, and
where the honest limits are. Support is never universal: a feature is available
only when CUPS, the queue, and its PPD expose it.

## Print path at a glance

1. **Device discovery.** `CUPSDeviceDiscovery` runs
   `/usr/sbin/lpinfo -v` directly, without a shell, with an English locale and
   a bounded timeout (25 seconds) so slow network and USB backends can answer. It parses USB, Bonjour/AirPrint, IPP/IPPS, socket
   and LPD candidates. Discovery candidates are not queues.
2. **Queue discovery.** `CUPSClient` runs `lpstat -e` to list configured
   queues, then enriches each queue with `lpstat -p <queue> -l` and
   `lpstat -v <queue>`.
3. **PPD discovery.** `PPDLoader` first checks the queue's configured PPD at
   `/etc/cups/ppd/<queue>.ppd` (or `.ppd.gz`), then the PPD path reported by
   `lpstat`, then searches `/Library/Printers/PPDs` as a fallback. A fallback
   candidate must share meaningful queue/model tokens; ambiguous matches are
   rejected rather than guessed.
4. **Option resolution.** `PPDParser` exposes the PPD's real options and
   choices. `PrintPresetResolver` maps quality presets onto those choices.
   Unrelated options are preserved.
5. **Submission.** The selected PPD keyword/value pairs are passed to
   `lp -o Keyword=Choice`. FlipStack never invents a PPD keyword or choice and
   never passes a shell string.

## Connections and discovery

| Connection | Example `lpinfo -v` URI | Transport reported by discovery | Queue required | Notes |
|---|---|---|---|---|
| USB | `usb://EPSON/L1800%20Series?serial=...` | `usb` | Yes | USB vendor/product names are percent-decoded. Serial numbers are not shown in the display name. |
| HP USB/backend | `hp:/usb/HP_OfficeJet_Pro_8720?serial=...` | `usb` | Yes | The HP backend is treated as a USB direct device for display purposes. |
| Bonjour / AirPrint | `dnssd://Epson%20L1800._ipp._tcp.local./?uuid=...` | `wifi` | Yes | The Bonjour service instance is decoded and the service suffix is removed. UUID queries are ignored for display. |
| AirPrint-style IPP URI | `ipps://Epson%20L1800._ipps._tcp.local./ipp/print` | `wifi` | Yes | An IPP/IPPS URI that still contains an `_ipp._tcp`, `_ipps._tcp` or AirPrint service type is treated as Bonjour/Wi-Fi. |
| IPP / IPPS | `ipp://host/printers/queue` | `network` | Yes | The queue path is used as the display name when it is descriptive; generic paths such as `/ipp/print` fall back to the host. |
| Raw socket | `socket://192.168.1.50:9100` | `network` | Yes | The host is the display name. Raw socket queues have no PPD unless one was configured manually, so PPD options are usually unavailable. |
| LPD | `lpd://host/queue` | `network` | Yes | The LPD queue name is used as the display name. |
| Serial, file, SCSI, `cups-brf` | `serial:/dev/...`, `file:/...`, `scsi:/...`, `cups-brf:/...` | Not returned | Not discoverable | These pseudo devices are ignored because they are not printers FlipStack can use through a normal CUPS print queue. |
| SMB and other backends | `smb://...` | Not returned | May be configured manually | Discovery only understands the listed schemes. A manually configured SMB queue can still print normally. |

Discovery rules:

- `dnssd://` is reported as `wifi`. Wi-Fi and Ethernet cannot be distinguished
  from a Bonjour service, so `wifi` means "local network" for display purposes.
- `ipp://`, `ipps://`, `socket://`, and `lpd://` are reported as `network`.
  FlipStack does not guess `ethernet` from a literal IP address, because that
  address can belong to either a Wi-Fi or an Ethernet printer. The `ethernet`
  transport value exists for configurations that know the link type; discovery
  itself never invents it.
- `usb://` and `hp:/` are reported as `usb`.
- Duplicate URIs are removed case-insensitively. Results are sorted USB first,
  then Wi-Fi, Ethernet, other network transports, and finally unknown
  transports. Ties sort by display name and then URI.
- Malformed lines, unsupported schemes, and error lines are ignored. An empty
  successful `lpinfo` result is an empty list, not an error.
- A missing `lpinfo`, a timeout, or a non-zero exit produces a descriptive
  `PrinterDiscoveryError`; a discovery failure never crashes the app.

**A discovered device is not yet a print destination.** To print to it, the
device must be added as a CUPS queue, for example from macOS System Settings >
Printers & Scanners, from the CUPS web interface at `http://localhost:631`, or
with `lpadmin`. FlipStack prints to the queue name, not directly to a URI.

## PPDs, driverless queues, and generic drivers

### Vendor PPD queues

A configured vendor PPD is the best case. `PPDLoader` reads the queue's PPD and
the preset engine can use every option the PPD exposes: resolution, print
quality, media type, tray, color mode, color profile, duplex, and so on.

### Driverless / IPP Everywhere queues

A driverless queue may have no local PPD. CUPS then relies on IPP attributes
and system defaults. FlipStack can still list, print to, and monitor such a
queue, but the PPD-driven features in this repository have nothing to read:

- no quality presets are offered by `PrintPresetResolver` for an empty PPD;
- PPD-specific color, media, profile, and tray choices are unavailable;
- basic layout and page selection still work because they are CUPS standard
  options rather than PPD options;
- capabilities depend on what the device advertises over IPP, not on
  FlipStack.

### Generic PostScript and sparse PPDs

Generic PostScript PPDs often expose only paper size, orientation, and duplex.
Presets are then incomplete: FlipStack applies the choices it can find and
leaves the rest to the base options or the system default. A preset is not
marked complete unless its quality and media capability groups were found and
resolved.

### Device types

- **Inkjet and photo printers** benefit most from the PPD preset engine when the
  PPD exposes resolution, print quality, media type, and a color mode. Photo
  media and ICC/profile choices are used only when they are real PPD choices.
- **Laser printers** usually expose resolution, media type, trays, and duplex.
  A monochrome laser may expose only a grayscale color mode; FlipStack selects
  it rather than pretending a color choice exists. High and Photo quality can
  still differ when the PPD has separate quality levels.
- **Thermal, label, and specialty printers** are supported only through their
  CUPS queue and PPD. FlipStack does not implement vendor label languages,
  cutter commands, or proprietary thermal settings. If the PPD exposes a
  setting, it can be used as a driver option; if not, it is out of reach.
- **Driverless IPP Everywhere devices** may print well without any of these
  PPD controls, but they cannot drive the PPD-based preset engine.

## Quality presets

`PrintPresetResolver` is UI-independent. It is initialized with a parsed
`PPDDocument` and exposes:

```swift
let resolver = PrintPresetResolver(ppd: document)
resolver.availablePresets                  // [PrintQualityPreset]
resolver.apply(.photo, to: baseOptions)    // PrintPresetApplication
resolver.matchingPreset(for: options)      // PrintQualityPreset?
```

A preset application contains the merged option dictionary, short applied
labels, and `isComplete`. Every value is either a real PPD choice or an unchanged
value from the caller's base options.

### How presets choose

The engine inspects PPD option groups and keywords, not hard-coded model names.

- **Quality options:** `Resolution`, `PrintQuality`, `RasterQuality`, and
  `cupsPrintQuality`. If more than one is present, all of them are set.
  Resolution choices are ranked by their numeric value (`360dpi`,
  `720x720dpi`, `1440dpi`, `2880dpi`). Label-based choices are ranked with
  Draft/Economy/Normal/High/Best/Photo-style tokens.
- **Media:** `MediaType` is preferred. `InputSlot` is used only when there is no
  `MediaType` and its choices actually describe media (Plain, Photo, Glossy,
  Matte, and similar). Tray-only values such as Automatic or Manual Feed are
  not treated as media types.
- **Color:** `ColorModel`, `ColorMode`, or `cupsColorModel`. FlipStack keeps
  color output when the PPD offers a color choice. It never forces grayscale on
  a color-capable PPD. If the PPD only offers grayscale, that real choice is
  selected. Color is set by every preset so the result is a complete bundle.
- **Profiles:** options whose keyword or label contains `profile` or `ICC` are
  treated as optional color-profile controls. Only the Photo preset changes
  them. Their absence never makes a preset incomplete.

Selection rules:

| Preset | Quality | Media | Color | Profile |
|---|---|---|---|---|
| Eco | Lowest ranked resolution/quality. | Explicit plain paper when available. | Color if available; grayscale only when that is the PPD's only mode. | Unchanged. |
| Standard | An explicit Normal/Standard/Medium choice when present; otherwise the lower-middle of the ranked choices. | Explicit plain paper. | Color if available. | Unchanged. |
| High | Highest ranked quality that is not explicitly photo-specific. | Plain paper, else the best non-photo media backed by a real PPD choice. | Color if available. | Unchanged. |
| Photo | Highest photo-specific quality when present, otherwise the highest ranked quality. | Photo/glossy media with the best real match; matte or premium media as fallbacks. | Color if available. | Best matching photo/Adobe RGB/sRGB profile, if one exists. |

Determinism:

- Ties keep the PPD's declaration order.
- Repeated applications produce identical dictionaries.
- `matchingPreset(for:)` ignores unrelated options such as paper size, tray,
  and duplex. It returns a preset only when exactly one preset matches the
  controlled quality, media, and color groups. An ambiguous match (for example
  Eco and Standard resolving to the same choices) and a modified/custom
  selection both return `nil`.

### `isComplete`

`isComplete` is true only when the capability groups the preset controls were
found and resolved to real choices:

- a quality group must exist and be selectable;
- a media group must exist and be selectable;
- Photo requires a photo-like media choice, not just any media;
- Eco and Standard require an explicit plain-paper choice;
- a color group that exists must be selectable;
- profile options are optional and do not affect completeness.

An incomplete preset is still usable. Missing groups keep the base/system
values, and the UI can show that some settings were not applied. An empty PPD
returns no presets from `availablePresets`, and any application is incomplete.

### Mapping to `lp -o`

The applied dictionary is passed through the existing option builder, so the
PPD keyword becomes the `lp` option name and the PPD choice keyword becomes its
value. For example:

```text
Resolution=1440dpi
PrintQuality=High
MediaType=PHOTO
ColorModel=Color
```

FlipStack passes these as separate arguments:

```sh
lp -d "EPSON_L1800" -o Resolution=1440dpi -o PrintQuality=High ...
```

The engine never sends a value that is not a choice in the PPD. If a queue has
no PPD, no PPD keywords are generated.

### Example mappings

Epson L1800 fixture:

| Preset | Resolution | PrintQuality | MediaType | ColorModel |
|---|---|---|---|---|
| Eco | `360dpi` | `Normal` | `PLAIN` | `Color` |
| Standard | `720dpi` | `Normal` | `PLAIN` | `Color` |
| High | `2880dpi` | `High` | `PLAIN` | `Color` |
| Photo | `2880dpi` | `High` | `PHOTO` | `Color` |

Brother HL-L2350DW fixture (monochrome laser, no photo media):

| Preset | Resolution | PrintQuality | MediaType | ColorModel | Complete |
|---|---|---|---|---|---|
| Eco | `600dpi` | `Normal` | `PLAIN` | `Gray` | Yes |
| Standard | `600dpi` | `Normal` | `PLAIN` | `Gray` | Yes |
| High | `1200dpi` | `High` | `PLAIN` | `Gray` | Yes |
| Photo | `1200dpi` | `High` | not changed | `Gray` | No |

The Photo row is intentionally incomplete: the printer has no photo or glossy
media, so FlipStack leaves the media at its base value instead of pretending
that plain paper is photo paper.

### Layout and page controls

Quality presets do not own page size or layout. Page size (`PageSize` /
`MediaSize` / `PageRegion`), tray (`InputSlot`), and duplex (`Duplex`) are
preserved unless a caller explicitly changes them. FlipStack's layout options
use CUPS standard fields rather than PPD values:

- `page-set=odd|even` for manual duplex passes;
- `page-ranges=...`;
- `number-up=2` for booklet imposition;
- `orientation-requested=3|4|5|6`;
- `sides=one-sided` when a manual pass must ignore hardware duplex.

FlipStack never sends `output-order=reverse` or any other page-reversal option:
the physical flip of the stack is what restores page order.

## Manual duplex, booklet, and hardware duplex PPDs

FlipStack's duplex and booklet modes are manual two-pass workflows. Each pass is
a separate CUPS job, and the user is prompted to flip or reinsert the stack
between passes.

When a printer's PPD advertises hardware duplex, the driver may otherwise decide
to turn pages on its own. For each manual pass, FlipStack forces:

```text
sides=one-sided
```

through `DuplexConfiguration.driverOptionsWithDuplex` when
`forceOneSidedPasses` is enabled. This is a CUPS/IPP option, so it works
independently of the PPD's own `Duplex` choice. A hardware-duplex printer still
uses the guided two-pass workflow; it is not switched to automatic duplex.

If `forceOneSidedPasses` is disabled, FlipStack instead sends the chosen
`Duplex=NoTumble` or `Duplex=Tumble` value. Simplex drivers may ignore it; the
physical workflow still determines the result.

Booklet mode creates two imposed PDFs and prints them with `number-up=2`. It
works with any queue that can print the generated PDF/PostScript. It does not
require hardware duplex.

## Compatibility matrix

| Connection | Driver / queue | PPD options | Manual duplex | Booklet | Status and ink | Notes |
|---|---|---|---|---|---|---|
| USB | Vendor PPD | Full set the PPD exposes | Yes | Yes | Queue state via `lpstat`; ink only if IPP/SNMP reports it | Best option coverage. Discovery reports `usb` and decodes vendor/product names. |
| USB | Driverless queue | System/IPP defaults only; no PPD options | Yes | Yes | Queue state; IPP attributes if available | Presets are unavailable without a PPD. |
| Wi-Fi / Bonjour | Vendor PPD | Full set the PPD exposes | Yes | Yes | Queue state; IPP/SNMP if available | Discovery reports `wifi`. Add the discovered device as a queue first. |
| Wi-Fi / AirPrint | Driverless IPP Everywhere | Device-advertised IPP defaults; no PPD options | Yes | Yes | Queue state; IPP often provides state and supplies | No PPD means no `PrintPresetResolver` choices. |
| Ethernet / IPP or IPPS | Vendor PPD | Full set the PPD exposes | Yes | Yes | Queue state; IPP/SNMP if available | Discovery reports `network`; link type is not inferred. |
| Ethernet / IPP Everywhere | Driverless | IPP defaults only | Yes | Yes | Often good IPP state/supply data | No PPD options. |
| Raw socket | Usually generic or manually supplied PPD | Only what the PPD exposes | Yes | Yes | Queue state only unless a separate status source exists | No discovery-time driver model. |
| LPD | Usually generic or manually supplied PPD | Only what the PPD exposes | Yes | Yes | Queue state only in most cases | Older protocol; no supply reporting. |
| HP backend (`hp:/`) | Vendor/HP PPD or generic | Only what the PPD exposes | Yes | Yes | Queue state; vendor status depends on the PPD/tooling | Discovery reports `usb` for the HP backend. |
| Generic PostScript | Generic PPD | Paper, orientation, duplex, maybe tray | Yes | Yes | Queue state | Expect incomplete presets and no color/media controls. |
| Serial / file / SCSI / `cups-brf` | Not discovered | Not applicable | Not via discovery | Not via discovery | Not applicable | These are not normal network/USB print destinations for FlipStack. |

"Manual duplex: Yes" means the queue can print the two generated jobs. It does
not mean the printer has a duplex unit, and it does not depend on PPD duplex
support.

## Diagnostics and troubleshooting

Useful commands:

```sh
# Devices visible to the CUPS backends
/usr/sbin/lpinfo -v

# Configured queue names
lpstat -e

# Queue state, description, PPD path, and alerts
lpstat -p "<queue>" -l

# Device URI actually used by the queue
lpstat -v "<queue>"

# Jobs still active on the queue
lpstat -W not-completed -o "<queue>"
```

Also check:

- macOS System Settings > Printers & Scanners for the queue and its selected
  driver.
- The CUPS web interface at `http://localhost:631`.
- `/var/log/cups/error_log` for backend and filter errors.
- The queue PPD at `/etc/cups/ppd/<queue>.ppd` or `.ppd.gz`; it must exist and
  be readable by the user running FlipStack.

### Discovery problems

- **"lpinfo was not found"**: the CUPS command-line tools are missing or the
  path is not `/usr/sbin/lpinfo`. FlipStack reports this as
  `PrinterDiscoveryError.toolNotFound`.
- **"lpinfo could not list available printers"**: check that the CUPS service
  is running and that the current user may query it. The error includes the
  exit status and the command output.
- **Discovery times out**: USB and network backends can be slow. The command has
  a 25-second limit. Refresh after a moment; check the backend with
  `lpinfo -v` in Terminal.
- **No devices**: the backends may be disabled. Verify with `lpinfo -v` and
  check `/var/log/cups/error_log`.
- **A device is visible but cannot be selected for printing**: it is a
  discovery candidate, not a queue. Add it as a CUPS queue first.
- **SMB or another unsupported scheme is missing**: discovery only returns the
  schemes documented above. A manually configured queue can still print.

### PPD and preset problems

- **No presets**: the PPD has none of the quality, media, or color groups the
  engine understands, the queue is driverless, or the PPD is unreadable. This
  is expected for an empty PPD.
- **A preset is incomplete**: the PPD does not expose a required group, or the
  group has no matching choice. For example, a monochrome laser has no photo
  media, so Photo is incomplete. The applied choices are still real; missing
  values stay at the base/system setting.
- **A preset is missing from `matchingPreset(for:)`**: the selection is custom,
  or two presets resolve to the same controlled choices. Returning `nil` is
  intentional rather than guessing.
- **Wrong media**: the PPD may use a vendor-specific media keyword. The engine
  only recognizes plain/photo/glossy/matte/premium vocabulary in keywords and
  labels. Inspect the PPD choice labels with `lpoptions -p <queue> -l` or by
  reading the PPD.
- **Wrong paper size or tray**: presets intentionally preserve page size, tray,
  and duplex. Set those separately.

### Duplex and booklet problems

- **Backs are upside down or in the wrong order**: recheck whether the output
  tray ejects face-up or face-down and whether the printer is configured for
  long-edge or short-edge flipping. FlipStack does not reverse page order; the
  physical flip does that.
- **The printer duplexes automatically during a manual pass**: enable
  `forceOneSidedPasses` so each pass sends `sides=one-sided`. This is required on
  PPDs that default to hardware duplex.
- **The last back is blank**: a document with an odd page count leaves the final
  back empty by design.
- **Booklet pages are out of order**: verify that both imposed PDFs were
  generated from the same source and that the queue honors `number-up=2`.

### Status and ink problems

- `lpstat` reports queue state and job state; it does not provide ink levels for
  every printer.
- Supply levels require a working IPP marker query or SNMP source. Many USB-only
  or older devices do not expose them.
- A stopped queue can be caused by a media, cover, or supply condition. Check
  `lpstat -p <queue> -l` and the printer panel before resuming the queue.
- `offline-report` is treated as a warning in FlipStack; it does not by itself
  prove that the queue cannot accept jobs.

## Reporting a printer

A useful compatibility report includes:

- macOS version and FlipStack version;
- printer make and model;
- connection type (USB, Wi-Fi, Ethernet) and the URI scheme, with hostnames,
  serial numbers, and UUIDs redacted;
- CUPS queue name;
- output of `lpstat -p "<queue>" -l` and `lpstat -v "<queue>"`;
- the relevant line from `/usr/sbin/lpinfo -v`;
- the PPD path/name and whether it is a vendor, generic PostScript, or
  driverless queue;
- the preset used, the applied labels, and whether `isComplete` was true;
- print mode (single-sided, manual duplex, booklet) and what happened physically;
- any error shown by FlipStack and the relevant `/var/log/cups/error_log` lines.

Do not include serial numbers, Bonjour UUIDs, network credentials, or other
device identifiers that should remain private.

## Limits

- CUPS is required. FlipStack does not talk to printers directly and does not
  replace a missing driver.
- A discovered device is not a print destination until it is configured as a
  CUPS queue.
- PPD options are the only vendor-specific options FlipStack can set. If the PPD
  does not advertise a feature, FlipStack cannot use it.
- Driverless queues have no PPD, so the quality preset engine has no choices to
  resolve. Basic CUPS layout options still work.
- Discovery does not infer Ethernet versus Wi-Fi from an IP address, does not
  support every CUPS backend, and ignores serial, file, SCSI, and `cups-brf`
  pseudo devices.
- Manual duplex and booklet are physical two-pass workflows. Their correctness
  depends on the printer's paper path, the user's flip, and the queue actually
  honoring the requested page set and imposition.
- Status and supply reporting depend on IPP or SNMP support. `lpstat` queue
  state is not a full device health API.
- FlipStack never claims support for a printer merely because it appears in
  discovery. Compatibility is determined by the queue, its driver, and the
  options that driver exposes.
