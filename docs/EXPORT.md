# Exporting a rig

What **File → Export current rig …** writes, and why it is shaped that way. It opens a
save panel, and what it saves is one zip file holding one folder named after the rig,
holding the same rig twice:

```
Crunch Lead.zip
└── Crunch Lead/
    ├── ljoss.json       this app's own document — the rig exactly as the library stores it
    └── namchain.json    the engine document DocumentEncoder lowers it to
```

The point is the handover. A rig that leaves this app can go to a CLI, a bug report, another
machine or another person, and it carries both halves so the receiver does not have to run
the encoder to find out what the rig *means*. `ljoss.json` is what this app reads back;
`namchain.json` is what the engine would be sent.

`namchain.json` is the document from [ENGINE.md](ENGINE.md) — the same one the session sends
over TCP — so `Tools/dump-engine-document.sh` and a zip of the same rig agree by
construction: both call `DocumentEncoder`.

## A refusal refuses the export

`DocumentEncoder` reports what it cannot lower: a block with no engine equivalent, an amp
with no model chosen, a cabinet with no impulse response chosen, a split mode that is not a
Y. **Any refusal fails the whole export**, with the encoder's own words, and the window says
why:

> This rig cannot be sent to namchain yet: Guitar · Brit 800 needs an amp model chosen from
> the device's library. Fix that and export again.

Every reason is reported at once, not the first one — `EncodeResult.refusals` is a list for
exactly this, because a user fixing one problem per attempt would be told about the second
problem only after they had fixed the first.

The alternative was to write `namchain.json` anyway, with the unlowerable blocks missing.
That file would load and it would play, and it would be quietly short an amp. A rig that
cannot be played is a thing to be told about, not a thing to discover on stage. It is also
what makes a zip worth having only one shape: **if there is a zip, the rig in it plays**.

Two consequences worth knowing:

- **A rig with an amp but no model chosen cannot be exported.** That is the state the
  starter rigs are in — they name no model and no impulse response — so the first export a
  new user tries is refused until they pick one. The refusal names the block, which is the
  same thing the editor shows on the node.
- **The export does not check the device's library.** It cannot: the device may not be
  connected, and the app's own Models & IRs listing is a separate thing
  ([ASSETS.md](ASSETS.md)). The engine document carries the model id the rig names, and the
  device refuses an id it does not have when the document reaches it — and, before that,
  `EngineSession`'s pre-flight does.

## The spelling of the two files

**`ljoss.json` is byte for byte the file the library writes.** Both go through `RigJSON`
(`Store/RigJSON.swift`): pretty-printed, keys sorted, ISO-8601 dates, written atomically.
One encoder rather than two configured alike, because two would drift the first time one
gained a setting, and the failure would be silent — a file that still loads, but is not the
file the library wrote. The tests assert the equality rather than the format, so an export
and a library save cannot diverge without a test failing.

A rig that does not decode still costs only that rig (see
[ARCHITECTURE.md](ARCHITECTURE.md#persistence)), which is what makes a single rig file worth
exporting on its own.

**`namchain.json` uses `EngineDocument.jsonData(pretty:)`** — keys sorted and slashes
unescaped, for the same reason: a document is a thing people read and diff, and Swift's
per-process string hashing would otherwise shuffle a node's keys between runs.

**Nothing in the archive is timestamped.** Zip entries carry a fixed 1980-01-01 date, so
exporting one unchanged rig twice produces byte-identical zips and a diff between two
exports shows what actually changed about the rig.

## Names

The folder is the rig's name. An entry name inside a zip is a *path*, so the name is
sanitised before it is used (`RigExport.folderName(for:)`):

- `/`, `\`, `:` and control characters become spaces, so "Guitar / Vocal" is one folder
  called "Guitar Vocal" rather than two;
- segments that are empty, `.` or `..` are dropped, so a rig called `../../etc/passwd`
  exports as `etc passwd` — a name that can neither become a path nor climb out of the
  folder it was unpacked into (zip-slip);
- a name that sanitises away entirely falls back to `Rig`.

Non-ASCII names survive: entries are written with the UTF-8 name flag set, and the reader
refuses a name that is not marked as UTF-8 rather than decoding it as CP437.

The suggested *file* name in the save panel is the same sanitised string, with `.zip`
appended.

## The zip itself

`Store/ZipArchive.swift` writes and reads the format's **stored** subset: no compression, no
zip64, no encryption, no data descriptors. Foundation has no archiver — `FileManager` has no
zip, and `NSFileCoordinator`'s `.forUploading` trick is macOS-only API that this multiplatform
target cannot reach — so the choice was a package dependency for two files in one folder, or
this. A few kilobytes of JSON do not need deflating, and an archiver that had to be trusted
about a deflate stream would be a liability.

What it writes is what `unzip`, `ditto`, Finder, Python's `zipfile` and
`System.IO.Compression` read; that is asserted by hand during development and by the central
directory in the tests, which is the part a real unpacker uses.

## Where the pieces live

| Piece | File | In the fast test set |
| --- | --- | --- |
| The archive format | `Store/ZipArchive.swift` | yes |
| Building the two files | `Store/RigExport.swift` | yes |
| How a rig is spelled as JSON | `Store/RigJSON.swift` | yes |
| Which rig is current | `Store/RigSelection.swift` | yes |
| The "and then" and the error | `App/ExportController.swift` | yes |
| The save panel | `App/SavePanel.swift` | yes |
| The menu item | `App/ExportRigCommands.swift` | no — it is `Commands` |

`RigSelection` exists because a menu command is not inside the window's view hierarchy: the
sidebar sets the selection, the editor is built from it, and the File menu has to see the
same value. See its own comment for why `@FocusedValue` was rejected.

## What is not here

- **No import.** This is one half of a transfer format; reading a zip back is not built.
  `ZipArchive` can already read one, which is what the tests use.
- **No iOS trigger.** The menu item is macOS's — `Commands` is the menu bar — so the iOS
  build has the export path and the panel's iOS branch returns nil. `ExportController`
  reports that rather than failing silently if it is ever reached there.
