# The local model and IR library

What Settings → Models & IRs lists, and why it is built the way it is.

This is **not** the device's library. A rig names its amp model and its impulse response
by the id `engine.assets` gave it, on the device that will play it
([ENGINE.md](ENGINE.md)); this is the app's own reading of files on the user's disk, and
nothing here is sent to namchain. There is no write path on either side — namchain's
`docs/assets.md` says so for the daemon, and this feature says it for the app. What the
page is for is telling the user what they have.

The vocabulary is deliberately namchain's, so that the two libraries describe the same
file the same way: an id is the path under its root without the extension, a `.wav` is an
impulse response, a `.nam` is a model *unless* its architecture is `Linear` — the core's
own container for a convolution — and a number that could not be read is `nil` rather
than zero.

## Folders, and identity

The user configures a list of folders. Each one is stored with three things: a path, a
bookmark, and an id.

**An entry is identified by its folder's id plus its path under that folder**, never by
an absolute path. On iOS the app's container moves between launches, so an absolute path
is a memory of where a file *was*; keying on it would make the whole library look removed
and re-added after an update. The bookmark is what survives a relaunch — created
security-scoped, resolved with a fall back to a plain bookmark and then to the stored
path, and re-resolved on every load so the stored paths follow a container that moved.

On macOS the app is not sandboxed, so a path is enough; the bookmark is still written,
because one code path that works on both platforms beats two that each work on one. On
iOS a folder whose bookmark cannot be made is **refused with a message** rather than
added: a folder that is there this session and gone the next is worse than one the user
was told about.

## The scan

A scan walks each folder recursively, skipping hidden names and bundles, taking `.nam`
and `.wav`, and refusing symlinks — the daemon's rules, for the daemon's reason: an id
promises "a file in this library", and a link out of it would make that a promise the
list cannot keep.

**The cache key is size and modification date.** A file that matches the entry the last
scan stored is carried over unread, keeping its parse *and* the day it was first added;
a file that does not match is read again; a file that is gone takes its entry with it.
`stats.parsed` counts the files whose headers were actually read, so "only re-read what
changed" is asserted in `Tests/AssetTests.swift` rather than claimed in a comment — a
second scan of an unchanged library is one that parsed zero files. The daemon keeps the
same cache for the same reason, down to the sub-second timestamp.

Three decisions worth recording, because the alternatives are all defensible:

- **A folder that is missing is an empty library, not a failure.** It contributes no
  files, its previous entries are pruned by the same rule as anything else that was not
  found, and the row says "Folder not found". The alternative — keeping the entries of a
  folder that is not there — lists files that cannot be read, and an external drive that
  comes back re-adds them with a fresh "added" date either way.
- **A folder configured inside another does not list its files twice.** Files are
  de-duplicated by resolved path, and the first folder in the list keeps them.
- **Nothing watches a folder and nothing scans on a timer.** The scan runs on the first
  appearance of the page in a session, when the folder list changes, and when the user
  presses Rescan. The daemon takes the same line: a library that changes underneath is
  something an operator should be able to do deliberately.

Scanning runs off the main actor in one detached task, with security-scoped access
started and stopped inside the folder it belongs to — which is why the walk is
synchronous and has no suspension points. A scan superseded by a folder change is
dropped by a generation counter rather than published over the newer answer.

## Reading a file

`NAMSniff` reads a **window**, not the file: the front 16 KiB and the last 1 KiB of a
`.nam`, and the first 4 KiB of a `.wav`. A model's weights are megabytes of JSON numbers,
so parsing every file whole would make a scan of a real library cost seconds and hundreds
of megabytes, and nothing functional depends on the answer — *loading* a model is what
decides whether it is usable. The window sizes are the daemon's, so both sides give up on
the same files.

What is read:

| | From | Gives |
| --- | --- | --- |
| `.nam` | front | `metadata` (name, `gear_make`, `gear_model`), `architecture` |
| `.nam` | tail | `sample_rate`, which the reference writer puts *after* the weights |
| `.wav` | header | `fmt ` rate, channels and bit depth; `data` length in frames |

The `metadata` object is found by brace matching — string- and escape-aware — and then
parsed with `JSONSerialization`, rather than pattern-matching fields out of the window,
where a `"name"` inside the training settings would be indistinguishable from the
capture's own name. An object the window cut in half is reported as absent: a field that
is not in the window is `nil`, which the row draws as a dash, and `nil` is the honest
answer for "the file did not say" and for "the file could not be read" alike.

## The make

"Make" is brand or manufacturer, and almost nothing in a NAM library declares one — the
format has `metadata.gear_make`, and a capture made by a stranger with an empty metadata
block has nothing at all, which is the common case for a folder someone else collected.

So it is a table, not magic, and it resolves in one order:

1. **The file's own claim.** A claim that names the amp as well as the brand —
   `Orange Rockerverb mk3` — is reduced to its brand, because that is what groups;
   a claim that names nothing known is used as it stands.
2. **The folder, then the filename.** Whole words only, alias list included: `ORNG` is
   Orange, `V30` and `SM57` are Celestion and Shure, because that is what a cabinet
   capture is named after and grouping a folder of them by model is not grouping by
   brand.
3. **`Unknown`** — a real group, sorted last wherever makes are ordered, so the bucket
   nobody wants is never at the top.

## Grouping and sorting

Four choices, held in `@AppStorage` beside the canvas's wrap toggle, because they are
viewing preferences rather than library data:

| | Options | Default |
| --- | --- | --- |
| Group by | None, Type, Path, Make | Type |
| Then by | None, Type, Path, Make | Make |
| Sort by | Type, Filename, Make, Name, Added, Updated | Make |
| Then by | (same) | Updated |

A second level equal to the first, or None, collapses: a heading that never varies is not
a heading. Text sorts A–Z, dates sort newest first (that is the question a date column is
asked), `Unknown` sorts last, and ties fall through name → path → folder, so the same
data drawn twice puts every row in the same place.

## The indicator

Scanning disables the results list and dims it — it can change under the pointer the
moment the scan publishes. The rows are read-only today, so the dimming is what the user
actually sees; the disabled state is what keeps any control a row gains later from being
live mid-scan. The folders and the display choices stay live, because they are what
starts the next scan and changing one mid-scan simply supersedes it — the superseded
scan's result is dropped by a generation counter rather than published over the newer
one.

The indicator is a row that is **always there**, 32 points tall, whose contents fade:
scanning, then "N files, A added, U updated, R removed", then nothing five seconds
later. A row that came and went would move the list under the pointer exactly when the
user is reading it, so it keeps its shape and shows information only when there is some.

## Stored where

One JSON file, `~/Library/Application Support/RigDesigner/AssetLibrary.json`, written
atomically on every change. One file rather than one per entry, unlike rigs: this is app
state rather than a document someone would mind losing one of, and a corrupt file starts
an empty library with a message rather than silently listing nothing.

`AssetKind` decodes an unknown raw value as a model instead of throwing, on the same
argument `docs/ARCHITECTURE.md` makes for `Block.componentID` being a `String`: a file
written by a build that knows a kind this one does not must not cost the user their
folder list.

## What is not here

- **No way to give a model to namchain.** The device's library is the daemon's, and a
  document names an id from it; connecting the two is a separate feature with its own
  questions (uploading, ids that collide, a device that is offline).
- **No editing, renaming, tagging or favourites.** The library lists what is on disk.
- **No presets or folders of its own.** The directory tree is the filing.
