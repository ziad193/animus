# Animus

*Animus* is Latin for "mind". It's a lightweight, native macOS flashcard app that works with your Anki decks.
It runs on Anki's own open-source engine, so scheduling (including FSRS) behaves exactly
like the official apps, and your cards stay in standard Anki format.

## How it fits together

```
Sources/StudyApp      SwiftUI screens (what you see)
Sources/StudyCore     Swift wrapper around the engine, with no UI code
Sources/CStudyEngine  C header describing the engine's functions
engine/               Small Rust bridge → Anki's engine (vendor/anki/rslib)
```

The icon is a placeholder drawn by `make-icon.swift` (`swift make-icon.swift`, then `iconutil -c icns AppIcon.iconset`).

Swift talks to the Rust bridge through a few C functions, and data comes back as JSON.

## What's in it

- First-run setup: your name (which names your profile), an optional 2-minute “How it works” tour for
  people new to Anki (why spaced repetition works, a card to try, the three numbers, decks, card types),
  then AnkiWeb sign-in, copying an Anki profile, a deck file or a fresh start, and a theme
- Profiles, like Anki's: each has its own cards, settings, exams, study time and AnkiWeb account
- Home (no sidebar): today's counts, time studied, Continue (your last deck, while it has cards left),
  quick actions, exam countdowns, a review heatmap and deck tiles. The deck sidebar appears while studying or browsing
- A cog on every deck: Rename (or move under another deck), Options (daily limits, learning steps,
  intervals, leeches, FSRS, burying; shared presets are flagged), Export to .apkg, and Delete with Undo
- Preferences: appearance, when the study day starts, learn-ahead, card order, what the study screen shows,
  a study time limit, and the Pomodoro timer
- A study timer that runs on the study screen and pauses on breaks, in other apps, or after 3 idle minutes
- Studying: smooth card swaps, theme-matched cards, keyboard shortcuts, and native image occlusion.
  A row of buttons above the card: Edit (E), Flag (⌘1–7), Mark (*), Bury (-), Suspend (@), Info (I) and
  More (set due date, reset to new, delete note ⌘⌫), all undoable with ⌘Z. Card Info shows the card's
  numbers and full review history. Leeches get a notice. When a deck is finished, one click adds
  +10 new cards or +50 reviews for today; the deck cog has Study More Today… for any amount
- A Slides & Notes panel: several files per deck as tabs (copied into the app so they keep opening).
  PDFs get page buttons, zoom and search with a match count. PowerPoint, Keynote and Word show their pages
  via Quick Look, and PowerPoint and Word also have a searchable Text view (slide text and speaker notes)
- Add Cards: card types shown as tiles with explanations, a live preview, Make blank for cloze,
  and a type-to-search deck picker with recent decks as one-click chips (it can create decks too).
  Fields are rich editors: bold/italic/underline, super/subscript, colour and highlight, lists; paste or
  drag in pictures and sounds (saved to the media folder like Anki), attach files, record your voice;
  pin a field to keep it for the next card; a warning when the front matches a card you already have
- Hide Parts of a Picture (image occlusion): choose, paste or drop a diagram, drag boxes or ovals over
  labels, group boxes onto one card, pick Hide all / Hide one; saved as Anki's own Image Occlusion type
- Search box in the toolbar on every page, and a Browse page: every card in a sortable table,
  filter buttons (Due today, New, Learning, Suspended, Added today, Flagged), a deck filter,
  a preview and an editor that shows fields as they look (with a Show HTML switch), and Suspend / Move / Delete with Undo.
  Also: Flag and Tags buttons, flag-colour filters, a Cards / Notes switch, Duplicates (with “tag all”), and
  More: set due date, reset to new, reposition new cards, find & replace, change card type
- Stats for all decks or one: heatmap, streak, retention, card breakdown, coming up, true retention
  (today → all time, young vs mature), best time of day, gaps between reviews, and answer buttons. And a Pomodoro timer
- Housekeeping: New Deck on Home, Import takes .apkg/.colpkg and spreadsheets (.csv/.tsv/.txt, with
  header detection and duplicate handling), and Preferences › Collection has Check Database, Check Media
  (unused files to the media trash, tag notes with missing files) and Export Everything (.colpkg)
- Sync with AnkiWeb (or your own sync server): sign in once, then it syncs on launch, after each
  study session and every 30 minutes, plus pictures and sounds. Only the server's sign-in key is kept,
  in the Keychain. If the two copies can't be merged, you choose which to keep

## Building

You need Swift (Xcode Command Line Tools) and Rust.

```bash
./build-engine.sh   # slow the first time; builds Anki's engine
./build-app.sh      # builds build/Animus.app (Apple Silicon only, quick)
open build/Animus.app
```

To share the app, build one that runs on both Apple Silicon and Intel Macs (needs
`rustup target add x86_64-apple-darwin` once):

```bash
./build-app.sh --universal
```

## Releases and updates

Animus checks GitHub once a day for a newer release (Preferences › General can turn this off).
The repository it checks is `AnimusUpdateRepository` in `Info.plist`. To release a new version,
raise `CFBundleShortVersionString` in `Info.plist`, build with `--universal`, zip `build/Animus.app`,
and publish a GitHub release tagged with the version (e.g. `v0.2.0`) with the zip attached.

`vendor/anki` is Anki 26.09.4, pinned as a git submodule. After cloning, fetch it with
`git submodule update --init --recursive`.

`tools/protoc` is the protobuf compiler (36.2), which isn't committed: download `protoc-36.2-osx-universal_binary.zip`
from the [protobuf releases](https://github.com/protocolbuffers/protobuf/releases) and unzip it into `tools/protoc`.

## License

AGPL-3.0-or-later (see [LICENSE](LICENSE)), because the app is built on Anki's engine.
Anki is © Ankitects Pty Ltd and contributors. This app isn't affiliated with or endorsed by Anki.

MathJax (in `Resources/mathjax`) is © The MathJax Consortium, Apache License 2.0 (see `Resources/mathjax/LICENSE`).

## Testing sync without a real account

Anki's engine includes a sync server. Build it with `cargo build --release -p anki-sync-server`
inside `vendor/anki` (with the same environment variables as `build-engine.sh`), run it with
`SYNC_USER1=test:testpass SYNC_HOST=127.0.0.1 SYNC_PORT=27701`, then:

```bash
.build/debug/study-cli <copy-A>/collection.anki2 synctest <empty-B>/collection.anki2 http://127.0.0.1:27701/
```

To try the app itself on a throwaway collection, launch it with `ITERUM_DATA_FOLDER=/some/folder`.
It then uses its own sign-in, so it can never sync your real collection.
