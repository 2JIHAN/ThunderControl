# Text clipboard (0.9.11)

ThunderControl can share newly copied plain text with the paired Mac over the existing encrypted session. It is off by default and separate from image sharing.

## Turning it on

Both Macs need 0.9.11 or later. Enable "Share copied text with the paired Mac" on both Macs (preference key `ThunderControl.textClipboard.enabled`). The image checkbox never enables text. The status line shows "Text clipboard ready" only after both Macs advertised the text codec, both sent text consent for the current epoch and the session is in a safe state.

A 0.9.10 peer keeps working for images only; it never receives text packets or text consent.

## What is shared

- Only the plain `.string` representation, as strict UTF-8, 1 byte to 1 MiB. Whitespace, newlines, Korean, emoji sequences and NUL are kept byte for byte. Empty copies are ignored and never clear the other Mac.
- HTML, RTF, file URLs, file lists, file promises and file contents are never requested. If a copy carries file or promise types, its text (for example a Finder path) is not read.
- Remote (Universal Clipboard), concealed, transient, auto-generated and ThunderControl-received items are skipped before any data is read.
- If both Macs allow images and the copy has PNG or TIFF, the image is sent and text is not read, even if the image fails validation.
- The received text is written with the existing `local.thundercontrol.received-image` marker and `.currentHostOnly`. This stops that one item from echoing or propagating; it does not disable Apple Universal Clipboard for later local copies.

The 1 MiB limit is a wire limit. The pasteboard IPC that supplies the data is not bounded by ThunderControl.

## Design

One serial pasteboard worker owns the change count, generation, epoch and transfer ordering for both kinds (`ClipboardTransferKind.png` and `.textUTF8`). The latest local copy wins across kinds. Each kind has its own enable flag, peer consent, capability and wire envelope:

- Image: unchanged `kind:"imageClipboard"` with `ImageClipboardPacket`.
- Text: `kind:"textClipboard"` with `TextClipboardPacket`, which has `format:"utf8"` on every operation. Hello advertises `textClipboardCodec:1`; text is negotiated only with image isolation codec 1 as well.

ACK and cancel must match both kind and transfer ID. Revocation (lock, bridge quarantine, session change, OFF) clears both kinds, and the send gate turns any queued stale chunk into a cancel of the same kind before bytes are written. Status and diagnostics never contain clipboard contents.

## Tests

`runTextClipboardTests()` in `Tests/TextClipboardTests.swift` uses named pasteboards only. Wire checks are in `Tests/ImageClipboardWireTests.swift`. Both run in `--self-test`.

Not verified by these tests: two physical Macs, Handoff/Universal Clipboard HUD behavior, or OS settings.
