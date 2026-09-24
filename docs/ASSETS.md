# The local model and IR library

What Settings → Models & IRs lists, and why it is built the way it is.

This is **not** the device's library. A rig names its amp model and its impulse response
by the id `engine.assets` gave it, on the device that will play it
([ENGINE.md](ENGINE.md)); this is the app's own reading of files on the user's disk, and
nothing here is sent to namchain. Nothing is written back into the library on either side —
namchain's `docs/assets.md` says so for the daemon, and this feature says it for the app;
the ratings and uses the finder keeps are user data *about* the files, not changes to them.
What the page is for is telling the user what they have, and letting them find it.

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

A scan is **two passes**, and the split is what the progress bar is built on. The first
walks the folders and reads only metadata — size and modification date — so it can say how
many files have to be opened without opening any. The second opens exactly those files,
several at a time; each one read is reported as it lands. A scan that finds ten files and
has to read four of them therefore shows `0/4` before the first byte and `2/4` once two
are done, rather than a bar whose maximum appears only at the end.

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
- **Nothing watches a folder and nothing scans on a timer.** The scan starts at launch,
  in the background, so the listing is normally fresh before anyone opens the page; it
  runs again when the folder list changes and when the user presses Rescan. Until it
  finishes, the entries restored from the last session are shown and dimmed under the
  scanning indicator rather than hidden. The daemon takes the same line: a library that
  changes underneath is something an operator should be able to do deliberately.

Both passes run off the main actor in one detached task, and the reads fan out inside it:
`AssetScan.parallelism` is the machine's core count, bounded to between two and eight,
because a header is a little I/O and a little JSON and past that the extra concurrent
opens buy file descriptors rather than throughput. Security-scoped access is opened for
every folder before the walk and held until the last file is read — on iOS a file is only
readable while its folder's scope is open, and the reads run on several threads at once. A
scan superseded by a folder change is dropped by a generation counter rather than
published over the newer answer.

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
| `.nam` | front | `metadata` (name, `gear_make`, `gear_model`, `gear_type`), `architecture` |
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

## Finding a model

Settings → Find Models is the same listing with the finding machinery in front of it, and
it is also the **model picker** for a node that runs a NAM capture: the inspector's Model
row pushes the same view, and a row chooses the model instead of doing nothing. One view
for both jobs, so the two cannot drift.

**A search is a set of words, and all of them must match.** The query is split on anything
that is not a letter or a digit; every word must be found in some word of an entry — its
name, its file name, its path, its make, its model, its architecture, its gear type — as a
whole word or as part of one. `ampeg svt` therefore finds `Ampeg ABC SVT123`, because
`SVT` is inside `SVT123`, and finds nothing that has only one of the two. Matching is
case- and diacritic-blind and runs over the entries already in memory: a scan finished long
before the page is opened, and searching never touches the disk.

**The words searched before are chips under the box.** `OneLineFit` lays them out in one
row and stops placing at the container's edge, so the row shows as many as fill the line
and no more — a scroll view would hide the rest off-screen and a wrapping stack would move
it to a second line. They are ranked most-recent-first, most-used-second, word last, so
the row is stable between two draws of the same history. Tapping one appends it to the box
unless the box already contains that word.

**Typing is debounced, not searched per keystroke.** `.task(id:)` cancels the previous task
when the query changes and `Task.sleep` throws on cancellation; 300 ms of quiet is one
search, and Return runs it at once. There is no timer and no Combine pipeline. The words of
a *settled* search are the words remembered, which is what makes a chip "a word that was
searched for" rather than "a prefix somebody typed on the way to one".

**Three filters.** *Type* is All / Amp / Amp + Cab: "Amp + Cab" is a model whose
`metadata.gear_type` is `amp_cab` or `amp_pedal_cab`, and "Amp" is everything else —
including a file that declared nothing, because absence is not a claim. An impulse response
is neither, so both options exclude it; they are about NAM captures, which is what they say.
*Previously Used* is All / Yes / No over the used list below. *My Rating* is No filtering /
All (rated) / Minimum (rated), plus a row of stars: choosing a star sets the minimum and
switches the drop-down to Minimum (rated) if it was somewhere else, so the two controls
never disagree about what is being asked.

**A use is written down when the user commits.** The editor notes the model picked in a
node when that node's config closes — including by deselecting on the canvas — when the app
leaves the foreground with the model still picked in the active rig, and when the active rig
is changed. A model already in the list has its last-used date moved rather than being added
twice. "Previously Used" then asks a question about that list, not about the files.

## What the user has said about a model

Ratings and uses are **user data, not library data** — nothing on disk implies them — so
they are kept in `NSUbiquitousKeyValueStore`, the app's iCloud key-value store, as one JSON
blob under one versioned key. iCloud is what makes a rating survive the app being deleted
and re-installed, which is the point of keeping it at all. The store only works in a
**code-signed** build carrying the `com.apple.developer.ubiquity-kvstore-identifier`
entitlement: with the entitlement but no iCloud account signed in it persists locally and
never syncs, and without the entitlement it is inert — every write silently no-ops. That is
why the target is signed and carries `RigDesigner/RigDesigner.entitlements`; an ad-hoc or
unsigned build loses this data without saying so.

A rating is filed under `AssetEntry.userKey`: the path under its folder without the
extension — the id a document names a file by — lowercased. It is deliberately **not**
`AssetEntry.id`, which begins with a root UUID that is fresh every time a folder is added.
The cost is that moving or renaming a file loses its rating; the alternative is a rating
that dies with an app update, which is the thing this exists to prevent. One blob under one
key rather than a key per model because the value is small, it is always read and written
whole, and the store's keyspace is shared.

The store is written only when something actually changed: closing a node's config with
nothing picked must not touch the key-value store, whose writes are quota'd and, with iCloud
on, are network traffic. The used list is capped, so a model older than a thousand others is
dropped rather than growing the blob without bound. A store this build cannot read starts
empty rather than failing, and a field a later build added does not cost the ratings this
one understands.

## The indicator

Scanning disables the results list and dims it — it can change under the pointer the
moment the scan publishes. Because the scan starts at launch, most visits find it already
finished and the list showing its result; when it is still running, what is dimmed is the
listing restored from the last session, so the page is never blank while it waits. The
rows are read-only today, so the dimming is what the user actually sees; the disabled
state is what keeps any control a row gains later from being live mid-scan. The folders
and the display choices stay live, because they are what starts the next scan and changing
one mid-scan simply supersedes it — the superseded scan's result is dropped by a
generation counter rather than published over the newer one.

The indicator is a row that is **always there**, 32 points tall, whose contents fade. It
has three states and none of them changes the row's height: a spinner and "Scanning
folders…" while the walk runs and the number of files is not yet known; a determinate bar
reading "Reading 4 of 12…" once the listing has said how many files have to be opened,
filling as each is read; then "N files, A added, U updated, R removed", then nothing five
seconds later. A row that came and went would move the list under the pointer exactly when
the user is reading it, so it keeps its shape and shows information only when there is
some.

## Stored where

One JSON file, `~/Library/Application Support/RigDesigner/AssetLibrary.json`, written
atomically on every change. One file rather than one per entry, unlike rigs: this is app
state rather than a document someone would mind losing one of, and a corrupt file starts
an empty library with a message rather than silently listing nothing.

The finder's user data does **not** live here. Ratings, uses and remembered searches are in
the iCloud key-value store, because they belong to the user rather than to this installation
of the app — see "What the user has said about a model" above.

`AssetKind` decodes an unknown raw value as a model instead of throwing, on the same
argument `docs/ARCHITECTURE.md` makes for `Block.componentID` being a `String`: a file
written by a build that knows a kind this one does not must not cost the user their
folder list.

## What is not here

- **No way to *send* a model to namchain.** A node picks a model with the finder and names
  it by its library id, so the device must already have a file with that id; putting the
  file there is a separate feature with its own questions (uploading, ids that collide, a
  device that is offline).
- **No editing, renaming or tagging.** The library lists what is on disk; the only things
  the app adds are the user's own ratings, uses and searches, which are kept apart from it.
- **No presets or folders of its own.** The directory tree is the filing.
