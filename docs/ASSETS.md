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

**The stored library is what the scan is given as that cache**, which is what makes the
cache outlive the process: the app opens the store at launch, hands the entries it finds
there to the scan, and a relaunch of an unchanged library parses nothing. Because that
equality is the whole mechanism, a store that rounded the date would quietly mean "every
file changed on every launch" — so what comes back out is asserted to equal what went in
(`Tests/AssetStoreTests.swift`), sub-second dates included.

Writing back is the same rule from the other side. `AssetSync` reconciles the scan's
result against what the store holds and touches only the rows that differ, so a scan of an
unchanged library writes nothing either. One save covers the folders and the files in
them, because they belong together.

Three decisions worth recording, because the alternatives are all defensible:

- **A folder that is missing is an empty library, not a failure.** It contributes no
  files, its previous entries are pruned by the same rule as anything else that was not
  found, and the row says "Folder not found". The alternative — keeping the entries of a
  folder that is not there — lists files that cannot be read, and an external drive that
  comes back re-adds them with a fresh "added" date either way.
- **A folder configured inside another does not list its files twice.** Files are
  de-duplicated by resolved path, and the first folder in the list keeps them.
- **Nothing watches a folder and nothing scans on a timer.** The scan runs when the app
  starts, when the folder list changes, and when the user presses Rescan. The daemon takes
  the same line: a library that changes underneath is something an operator should be able
  to do deliberately.

The launch scan is **awaited** before anything is pointed at a device. The local engine
gives the daemon the folder the scan found the user's models in
(`Engine/LocalEnginePlan.swift`), so starting it first would hand it yesterday's answer;
and because unchanged files are carried over from the store, waiting costs a walk of the
folders rather than a read of the library. A second window finds the work already done —
the scan is once per session, not once per window.

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

## Drawing the list

**The rows are drawn lazily and the sections are not.** The list is a `LazyVStack` inside
the scroll view, so only the rows in view — and a little either side of them — are built:
on a real 1603-file library that is 12 rows constructed instead of 1603, and about 70 ms
to open instead of 1.4 s, for pixels that are identical.

What is *not* lazy is the grouping and sorting above: it is a pass over every entry (tens
of milliseconds at that size), it is what the headings and the order come from, and every
section has to be known before the first one can be drawn. The list is a stack of sections
rather than a `List` because the page is a form with the results underneath it, and a
`List` there would bring its own selection, insets and separators with it.

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

SwiftData, in `~/Library/Application Support/Ljoss/AssetLibrary.store` — one store rather
than one file per entry, unlike the rigs: this is app state rather than a document someone
would mind losing one of.

Two `@Model` classes mirror the two value types: `AssetRootRecord` and
`AssetEntryRecord`. The value types stay the app's own representation, and the conversion
happens at this boundary, for one reason: an `AssetEntry` crosses into the scan's detached
task and is what the ordering sorts and the local engine reads, and a model object belongs
to the context that made it. The records are keyed by the same ids the scan reckons with
(`@Attribute(.unique)`), which is what lets a write touch only the rows that changed.

**What is read back has a stated order, because a fetch has none.** Folders come back in
the order they were added — that list is the user's, and the local engine gives the daemon
the *first* folder that holds a model, so an order that changed between launches would
change the daemon's library. Files come back by id, which is the order `AssetScan` leaves a
scan's own result in, so a list read from the store and a list just walked are the same
list in the same order.

`AssetKind` is stored as its raw string, and an unknown raw value reads back as a model
rather than throwing, on the same argument `docs/ARCHITECTURE.md` makes for
`Block.componentID` being a `String`: a file written by a build that knows a kind this one
does not must not cost the user their folder list.

**A library an older build wrote as JSON is imported once and deleted.** The build before
this one kept `AssetLibrary.json`; on the first launch whose store has never held
anything, the file is read, written into the store, and then deleted. It exists because
the folder list and each file's first-seen day are the two things a rescan cannot
rebuild — and it is deleted because leaving it would resurrect the folders of a user who
has deliberately emptied the library, which is worse than an empty list. It is skipped
entirely when the store is the in-memory fallback below: deleting a file on behalf of a
store that cannot take its place would be losing the only copy of that list.

A store that cannot be opened is a store the app works without. The container falls back to
one that is not written anywhere, the page says so, and the library still lists and scans —
it simply does not survive the session. That message is not cleared by a later write,
because nothing has actually been saved.

## What is not here

- **No way to give a model to namchain.** The device's library is the daemon's, and a
  document names an id from it; connecting the two is a separate feature with its own
  questions (uploading, ids that collide, a device that is offline).
- **No editing, renaming, tagging or favourites.** The library lists what is on disk.
- **No presets or folders of its own.** The directory tree is the filing.
