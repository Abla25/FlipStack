# Privacy and data handling

FlipStack is designed as a local macOS print utility. It does not collect, transmit, sell, or publish user data.

## What FlipStack stores

FlipStack stores a small amount of preference data in the current user's macOS defaults:

- The selected CUPS queue identifier and the last print mode.
- Per-queue PPD choices, layout choices, quality preset overrides, and physical flip setup.
- The selected interface language.
- Whether first-time flip setup has been completed.

It does not store the selected PDF, document text, page content, previews, its own print history, ink readings, account information, or the last file-picker folder. The app clears AppKit's last open-panel folder bookmark when the picker closes.

FlipStack submits CUPS jobs with generic titles such as `FlipStack fronts` and `FlipStack backs`; it does not send the document filename to CUPS or expose it in the `lp` process arguments. CUPS receives a private, neutrally named spool copy (`document.pdf`) that is removed immediately after submission. CUPS itself may retain job metadata and history independently of FlipStack. The queue panel reads recent jobs for the selected queue but displays only jobs owned by the current macOS/CUPS user or jobs submitted by this FlipStack session; it does not expose or offer cancellation for another user's jobs.

## What leaves the Mac

Nothing is uploaded to an analytics service, telemetry endpoint, cloud service, or advertising network.

The only network or process activity is related to printing:

- Local CUPS commands and status requests (`lp`, `lpstat`, `cancel`, and local CUPS/IPP).
- Printer discovery via CUPS `lpinfo`, which may generate local network/mDNS traffic.
- A print job sent to the CUPS queue the user selected. That queue may represent a printer on the local network or a directly connected USB printer.
- Optional read-only SNMP queries to the network printer named by the queue's device URI when CUPS does not provide supply levels. The queries are SNMP v1/v2c over cleartext UDP with the default community string `public`, limited to read-only Printer-MIB supply columns. FlipStack does not store or send the community anywhere else.
- Because of App Transport Security, a remote `CUPS_SERVER` is only contacted over `https`/`ipps` (or plain `http` to localhost); a cleartext remote host is blocked by the system and FlipStack falls back to local status.
- If the environment explicitly points `CUPS_SERVER` at a remote CUPS host, status requests go to that configured host. No document content is included in status requests.

There are no accounts, sign-ins, remote logging services, crash-reporting SDKs, third-party dependencies, or background uploads.

## Documents and temporary files

- PDFs are read only to prepare previews, page selections, booklets, or print passes.
- Temporary PDFs are written inside a user-only temporary directory, used for the local print operation, and removed after submission or preparation finishes. After a print failure, the prepared files may remain so **Retry backs** or **Start over** can work; they are removed when you dismiss/reset the flow, quit the app, or on the next launch. FlipStack creates the containing directories with `0700` and generated files with `0600` at creation time (never after the content exists), inside the per-user temporary directory.
- FlipStack removes its temporary working directory on launch and on normal quit. A force-quit or crash can leave files until the next launch; they are never uploaded.
- FlipStack does not create its own document history or recent-documents list. It does read the selected CUPS queue and its recent job metadata, which CUPS retains independently.
- The calibration sheet contains no document content. It is a generic orientation sheet and is safe to discard. The separate test and head-alignment sheets include the printer display name and local date/time by design; they are printed locally and are not uploaded.

## Notifications

FlipStack notifications are intentionally generic. They do not include the document name, page content, print-job title, printer name, or local file paths. Error details remain in the in-app panel.

## Repository and screenshots

The checked-in screenshots and demo fixtures use synthetic data (the demo set includes Field Notes, Annual report, Invoice batch, and Field Notes — fronts):

- Demo printer: EPSON L1800 Series
- Demo document: Field Notes
- Demo job names: Annual report, Invoice batch

No real customer document or personal print data is intentionally included. Automated fixtures use synthetic queue names, owners, and serial numbers.

## Removing local data

Quit FlipStack and remove its preferences with:

```sh
defaults delete app.flipstack.FlipStack
defaults delete app.flipstack.demo
```

Removing the app does not remove CUPS queues or printer drivers; manage those in **System Settings > Printers & Scanners**.

## Questions

Privacy questions can be raised privately through the repository owner. Please do not attach real documents, printer serial numbers, or queue exports to a public issue.
