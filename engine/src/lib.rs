//! The bridge between the Mac app (Swift) and Anki's engine (Rust).
//!
//! How it works, in plain terms:
//! - Swift calls a handful of simple C functions defined here.
//! - Requests and answers travel as JSON text, so the Swift side stays simple.
//! - Every string this file hands to Swift must be given back through
//!   `study_free_string`, so memory is released properly.
//!
//! License: AGPL-3.0-or-later (required because we use Anki's engine).

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::Mutex;

use anki::card_rendering::extract_av_tags;
use anki::collection::{Collection, CollectionBuilder};
use anki::decks::DeckId;
use anki::prelude::{CardId, I18n, NoteId};
use anki::scheduler::answering::{CardAnswer, Rating};
use anki::scheduler::states::SchedulingStates;
use anki::timestamp::{TimestampMillis, TimestampSecs};
use anki_proto::card_rendering::av_tag;
use serde::Serialize;

/// An open collection. Swift only ever sees a pointer to this.
pub struct Engine {
    inner: Mutex<Inner>,
}

struct Inner {
    col: Collection,
    /// The card currently on screen and its possible next states,
    /// kept so we can grade it.
    current: Option<(CardId, SchedulingStates)>,
}

impl Engine {
    fn lock(&self) -> Option<std::sync::MutexGuard<'_, Inner>> {
        match self.inner.lock() {
            Ok(guard) => Some(guard),
            Err(_) => {
                set_error("collection is busy or crashed");
                None
            }
        }
    }
}

fn to_json<T: Serialize>(value: &T) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(json) => to_c_string(json),
        Err(err) => {
            set_error(format!("could not encode result: {err}"));
            std::ptr::null_mut()
        }
    }
}

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_error(msg: impl Into<String>) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg.into()));
}

fn to_c_string(s: String) -> *mut c_char {
    // JSON never contains interior NUL bytes, but be safe anyway.
    CString::new(s.replace('\0', "")).map_or(std::ptr::null_mut(), CString::into_raw)
}

unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

// ---------------------------------------------------------------------------
// Opening and closing
// ---------------------------------------------------------------------------

/// Open (or create) a collection file such as `collection.anki2`.
/// Images and audio live next to it in `collection.media`.
/// Returns null on failure; call `study_last_error` for the reason.
///
/// # Safety
/// `path` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn study_open(path: *const c_char) -> *mut Engine {
    let Some(path) = (unsafe { str_arg(path) }) else {
        set_error("collection path was missing or not valid text");
        return std::ptr::null_mut();
    };
    match CollectionBuilder::new(PathBuf::from(path))
        .with_desktop_media_paths()
        .build()
    {
        Ok(col) => Box::into_raw(Box::new(Engine {
            inner: Mutex::new(Inner { col, current: None }),
        })),
        Err(err) => {
            set_error(format!("could not open collection: {err}"));
            std::ptr::null_mut()
        }
    }
}

/// Close the collection and free it. Safe to call with null.
///
/// # Safety
/// `engine` must come from `study_open` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn study_close(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    let engine = unsafe { Box::from_raw(engine) };
    if let Ok(inner) = engine.inner.into_inner() {
        let _ = inner.col.close(None);
    }
}

// ---------------------------------------------------------------------------
// Decks
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct DeckJson {
    id: i64,
    name: String,
    level: u32,
    new_count: u32,
    learn_count: u32,
    review_count: u32,
    total_cards: u32,
    filtered: bool,
    collapsed: bool,
    children: Vec<DeckJson>,
}

impl DeckJson {
    /// Anki's tree gives each deck only its own name ("Week 1"); we pass on
    /// the full name ("Biology::Week 1") so the app can show where it lives.
    fn from_node(node: anki_proto::decks::DeckTreeNode, parent: Option<&str>) -> Self {
        let name = match parent {
            Some(parent) => format!("{parent}::{}", node.name),
            None => node.name,
        };
        let children = node
            .children
            .into_iter()
            .map(|child| DeckJson::from_node(child, Some(&name)))
            .collect();
        DeckJson {
            id: node.deck_id,
            name,
            level: node.level,
            new_count: node.new_count,
            learn_count: node.learn_count,
            review_count: node.review_count,
            total_cards: node.total_including_children,
            filtered: node.filtered,
            collapsed: node.collapsed,
            children,
        }
    }
}

/// All decks with today's due counts, as a JSON list (the top level of the
/// tree; sub-decks are inside `children`). Returns null on failure.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_deck_tree(engine: *mut Engine) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    match inner.col.deck_tree(Some(TimestampSecs::now())) {
        Ok(root) => {
            let decks: Vec<DeckJson> = root
                .children
                .into_iter()
                .map(|node| DeckJson::from_node(node, None))
                .collect();
            to_json(&decks)
        }
        Err(err) => {
            set_error(format!("could not read decks: {err}"));
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Studying
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct Counts {
    new: usize,
    learn: usize,
    review: usize,
}

#[derive(Serialize)]
struct StudyCardJson {
    /// `None` when there is nothing left to study today.
    card: Option<CardJson>,
    counts: Counts,
}

#[derive(Serialize)]
struct CardJson {
    id: i64,
    /// Full HTML for each side. Audio is replaced by `study-play://q/0` links.
    question: String,
    answer: String,
    css: String,
    /// Sound files (relative to the media folder) for each side, in order.
    question_audio: Vec<String>,
    answer_audio: Vec<String>,
    /// When each button would show the card next, e.g. "<1m", "10m", "1d", "4d".
    intervals: Vec<String>,
    /// Question of the card queued after this one (for loading its images early).
    upcoming: Option<String>,
    /// Raw note fields for image occlusion cards, which the app draws natively.
    occlusion: Option<OcclusionJson>,
    /// 0 = none, 1–7 = red, orange, green, blue, pink, turquoise, purple.
    flag: u32,
    /// The note has the "marked" tag.
    marked: bool,
}

#[derive(Serialize)]
struct OcclusionJson {
    /// "enhanced" (the old Image Occlusion Enhanced add-on) or "builtin" (Anki's own).
    kind: &'static str,
    /// Which card of the note this is (1-based, like {{c1::…}}).
    ordinal: u16,
    fields: std::collections::HashMap<String, String>,
}

/// Collects the fields of image occlusion notes; `None` for any other card.
fn occlusion_fields(col: &mut Collection, card_id: CardId) -> Option<OcclusionJson> {
    let card = col.storage.get_card(card_id).ok()??;
    let note = col.storage.get_note(card.note_id()).ok()??;
    let notetype = col.get_notetype(note.notetype_id).ok()??;
    let names: Vec<&str> = notetype.fields.iter().map(|f| f.name.as_str()).collect();
    let kind = if names.contains(&"Question Mask") && names.contains(&"Image") {
        "enhanced"
    } else if names.first() == Some(&"Occlusion") && names.contains(&"Image") {
        "builtin"
    } else {
        return None;
    };
    let fields = names
        .iter()
        .zip(note.fields().iter())
        .map(|(name, value)| (name.to_string(), value.clone()))
        .collect();
    Some(OcclusionJson {
        kind,
        ordinal: card.template_idx() + 1,
        fields,
    })
}

/// Swaps Anki's `[anki:play:q:0]` markers for links the app can catch,
/// and returns the sound files in order (text-to-speech is skipped for now).
fn prepare_side(html: &str, question_side: bool, tr: &I18n) -> (String, Vec<String>) {
    let (mut text, tags) = extract_av_tags(html, question_side, tr);
    let side = if question_side { "q" } else { "a" };
    let mut files = Vec::new();
    for (index, tag) in tags.iter().enumerate() {
        let marker = format!("[anki:play:{side}:{index}]");
        let link = match &tag.value {
            Some(av_tag::Value::SoundOrVideo(file)) => {
                files.push(file.clone());
                format!(
                    r#"<a class="study-play" href="study-play://{side}/{}" aria-label="Play audio">▶</a>"#,
                    files.len() - 1
                )
            }
            _ => String::new(),
        };
        text = text.replacen(&marker, &link, 1);
    }
    (text, files)
}

/// Make `deck_id` (and its sub-decks) the deck being studied.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_select_deck(engine: *mut Engine, deck_id: i64) -> bool {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return false;
    };
    let Some(mut inner) = engine.lock() else {
        return false;
    };
    inner.current = None;
    match inner.col.set_current_deck(DeckId(deck_id)) {
        Ok(_) => true,
        Err(err) => {
            set_error(format!("could not select deck: {err}"));
            false
        }
    }
}

/// The next card to study in the selected deck, as JSON (`StudyCardJson`).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_next_card(engine: *mut Engine) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    match next_card(&mut inner) {
        Ok(result) => to_json(&result),
        Err(err) => {
            set_error(format!("could not get the next card: {err}"));
            std::ptr::null_mut()
        }
    }
}

fn next_card(inner: &mut Inner) -> anki::error::Result<StudyCardJson> {
    let queued = inner.col.get_queued_cards(2, false)?;
    let counts = Counts {
        new: queued.new_count,
        learn: queued.learning_count,
        review: queued.review_count,
    };
    let mut cards = queued.cards.into_iter();
    let Some(next) = cards.next() else {
        inner.current = None;
        return Ok(StudyCardJson { card: None, counts });
    };

    let rendered = inner.col.render_existing_card(next.card.id(), false, false)?;
    let tr = I18n::template_only();
    let (question, question_audio) = prepare_side(&rendered.question(), true, &tr);
    let (answer, answer_audio) = prepare_side(&rendered.answer(), false, &tr);
    let intervals = inner.col.describe_next_states(&next.states)?;
    // Best effort: a failure here shouldn't stop studying.
    let upcoming = cards.next().and_then(|after| {
        inner
            .col
            .render_existing_card(after.card.id(), false, false)
            .ok()
            .map(|r| r.question().into_owned())
    });

    let occlusion = occlusion_fields(&mut inner.col, next.card.id());
    let flag = anki_proto::cards::Card::from(next.card.clone()).flags & 0b111;
    let marked = inner
        .col
        .storage
        .get_note(next.card.note_id())?
        .map(|n| n.tags.iter().any(|t| t.eq_ignore_ascii_case("marked")))
        .unwrap_or(false);
    let card = CardJson {
        id: next.card.id().0,
        question,
        answer,
        css: rendered.css,
        question_audio,
        answer_audio,
        intervals,
        upcoming,
        occlusion,
        flag,
        marked,
    };
    inner.current = Some((next.card.id(), next.states));
    Ok(StudyCardJson { card: Some(card), counts })
}

/// Grade the card on screen: 1 = Again, 2 = Hard, 3 = Good, 4 = Easy.
/// `milliseconds` is how long the student looked at it.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_answer(engine: *mut Engine, rating: u8, milliseconds: u32) -> bool {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return false;
    };
    let Some(mut inner) = engine.lock() else {
        return false;
    };
    let Some((card_id, states)) = inner.current.take() else {
        set_error("no card is being shown");
        return false;
    };
    let (rating, new_state) = match rating {
        1 => (Rating::Again, states.again),
        2 => (Rating::Hard, states.hard),
        3 => (Rating::Good, states.good),
        4 => (Rating::Easy, states.easy),
        _ => {
            set_error("rating must be 1 to 4");
            inner.current = Some((card_id, states));
            return false;
        }
    };
    let mut answer = CardAnswer {
        card_id,
        current_state: states.current,
        new_state,
        rating,
        answered_at: TimestampMillis::now(),
        milliseconds_taken: milliseconds,
        custom_data: None,
        from_queue: true,
    };
    match inner.col.answer_card(&mut answer) {
        Ok(_) => true,
        Err(err) => {
            set_error(format!("could not save the answer: {err}"));
            false
        }
    }
}

/// Undo the last action (e.g. the last grade). Returns false if nothing to undo.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_undo(engine: *mut Engine) -> bool {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return false;
    };
    let Some(mut inner) = engine.lock() else {
        return false;
    };
    inner.current = None;
    match inner.col.undo() {
        Ok(_) => true,
        Err(err) => {
            set_error(format!("nothing to undo: {err}"));
            false
        }
    }
}

// ---------------------------------------------------------------------------
// Adding cards
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct NotetypeJson {
    id: i64,
    name: String,
    /// What it started life as: "basic", "reversed", "optional_reversed",
    /// "typing", "cloze", "occlusion", or "other".
    kind: &'static str,
    is_cloze: bool,
    fields: Vec<String>,
}

/// All note types (card types) in the collection, as JSON.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_notetypes(engine: *mut Engine) -> *mut c_char {
    use anki_proto::notetypes::notetype::config::Kind;
    use anki_proto::notetypes::stock_notetype::OriginalStockKind;
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    match inner.col.get_all_notetypes() {
        Ok(all) => {
            let list: Vec<NotetypeJson> = all
                .iter()
                .map(|nt| NotetypeJson {
                    id: nt.id.0,
                    name: nt.name.clone(),
                    kind: match nt.config.original_stock_kind() {
                        OriginalStockKind::Basic => "basic",
                        OriginalStockKind::BasicAndReversed => "reversed",
                        OriginalStockKind::BasicOptionalReversed => "optional_reversed",
                        OriginalStockKind::BasicTyping => "typing",
                        OriginalStockKind::Cloze => "cloze",
                        OriginalStockKind::ImageOcclusion => "occlusion",
                        OriginalStockKind::Unknown => "other",
                    },
                    is_cloze: nt.config.kind() == Kind::Cloze,
                    fields: nt.fields.iter().map(|f| f.name.clone()).collect(),
                })
                .collect();
            to_json(&list)
        }
        Err(err) => {
            set_error(format!("could not read card types: {err}"));
            std::ptr::null_mut()
        }
    }
}

#[derive(serde::Deserialize)]
struct AddNoteRequest {
    notetype_id: i64,
    deck_id: i64,
    fields: Vec<String>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Serialize)]
struct AddNoteResult {
    note_id: i64,
    cards: usize,
}

/// Adds a note from JSON (`AddNoteRequest`). Returns JSON with the new note id
/// and how many cards it made, or null with a friendly error.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_add_note(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::NotetypeId;
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(request) = (unsafe { str_arg(json) }).and_then(|j| serde_json::from_str::<AddNoteRequest>(j).ok()) else {
        set_error("the card details were not readable");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    let result = (|| -> Result<AddNoteResult, String> {
        let notetype = inner
            .col
            .get_notetype(NotetypeId(request.notetype_id))
            .map_err(|e| e.to_string())?
            .ok_or("that card type no longer exists")?;
        let mut note = notetype.new_note();
        for (index, value) in request.fields.iter().enumerate().take(notetype.fields.len()) {
            note.set_field(index, value.clone()).map_err(|e| e.to_string())?;
        }
        note.tags = request.tags.clone();
        let output = inner
            .col
            .add_note(&mut note, DeckId(request.deck_id))
            .map_err(|e| e.to_string())?;
        Ok(AddNoteResult { note_id: note.id.0, cards: output.output })
    })();
    match result {
        Ok(added) => to_json(&added),
        Err(message) => {
            set_error(message);
            std::ptr::null_mut()
        }
    }
}

#[derive(serde::Deserialize)]
struct CheckNoteRequest {
    notetype_id: i64,
    fields: Vec<String>,
}

/// Checks a note before it's added: "ok", "empty", "duplicate" (same first
/// field already exists in this card type), "missing_cloze" or "not_cloze".
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_check_note(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::NotetypeId;
    use anki_proto::notes::note_fields_check_response::State;
    unsafe {
        with_request(engine, json, |inner, req: CheckNoteRequest| {
            let notetype = inner
                .col
                .get_notetype(NotetypeId(req.notetype_id))
                .map_err(|e| e.to_string())?
                .ok_or("that card type no longer exists")?;
            let mut note = notetype.new_note();
            for (index, value) in req.fields.iter().enumerate().take(notetype.fields.len()) {
                note.set_field(index, value.clone()).map_err(|e| e.to_string())?;
            }
            let state = inner.col.note_fields_check(&note).map_err(|e| e.to_string())?;
            Ok(match state {
                State::Normal => "ok",
                State::Empty => "empty",
                State::Duplicate => "duplicate",
                State::MissingCloze => "missing_cloze",
                State::NotetypeNotCloze | State::FieldNotCloze => "not_cloze",
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct AddOcclusionRequest {
    deck_id: i64,
    /// The picture; it's copied into the media folder.
    image_path: String,
    /// Anki's format: `{{c1::image-occlusion:rect:left=.1:top=.2:width=.3:height=.1:oi=1}}`…
    occlusions: String,
    #[serde(default)]
    header: String,
    #[serde(default)]
    back_extra: String,
    #[serde(default)]
    tags: Vec<String>,
}

/// Adds an image occlusion note with Anki's own card type (made if missing).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_add_occlusion(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: AddOcclusionRequest| {
            inner.current = None;
            let col = &mut inner.col;
            // Anki adds the note to the current deck.
            col.set_current_deck(DeckId(req.deck_id)).map_err(|e| e.to_string())?;
            col.add_image_occlusion_note(anki_proto::image_occlusion::AddImageOcclusionNoteRequest {
                image_path: req.image_path,
                occlusions: req.occlusions,
                header: req.header,
                back_extra: req.back_extra,
                tags: req.tags,
                notetype_id: 0,
            })
            .map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

#[derive(serde::Deserialize)]
struct UpdateOcclusionRequest {
    note_id: i64,
    occlusions: String,
    #[serde(default)]
    header: String,
    #[serde(default)]
    back_extra: String,
    #[serde(default)]
    tags: Vec<String>,
}

/// Saves new boxes (and title / extra / tags) for an image occlusion note.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_update_occlusion(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: UpdateOcclusionRequest| {
            inner.current = None;
            inner
                .col
                .update_image_occlusion_note(NoteId(req.note_id), &req.occlusions, &req.header, &req.back_extra, req.tags)
                .map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

/// Adds one of Anki's standard card types if the collection doesn't have it,
/// e.g. decks made without "Basic (type in the answer)". JSON: "basic",
/// "reversed", "typing" or "cloze". Returns the new card type's id.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_add_stock_notetype(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, kind: String| {
            let index = match kind.as_str() {
                "basic" => 0,
                "reversed" => 1,
                "typing" => 3,
                "cloze" => 4,
                _ => return Err(format!("unknown card type “{kind}”")),
            };
            let tr = I18n::new(&["en"]);
            let mut notetype = anki::notetype::all_stock_notetypes(&tr)
                .into_iter()
                .nth(index)
                .ok_or("that card type isn't available")?;
            inner.col.add_notetype(&mut notetype, false).map_err(|e| e.to_string())?;
            Ok(notetype.id.0)
        })
    }
}

// ---------------------------------------------------------------------------
// Importing
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ImportResultJson {
    new: usize,
    updated: usize,
    duplicate: usize,
}

/// Imports an `.apkg` / `.colpkg`-style deck package, keeping its progress.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `path` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_import_apkg(engine: *mut Engine, path: *const c_char) -> *mut c_char {
    use anki_proto::import_export::{ImportAnkiPackageOptions, ImportAnkiPackageUpdateCondition};
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(path) = (unsafe { str_arg(path) }) else {
        set_error("file path was missing");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    inner.current = None;
    let options = ImportAnkiPackageOptions {
        merge_notetypes: false,
        update_notes: ImportAnkiPackageUpdateCondition::IfNewer as i32,
        update_notetypes: ImportAnkiPackageUpdateCondition::IfNewer as i32,
        with_scheduling: true,
        with_deck_configs: true,
    };
    match inner.col.import_apkg(path, options) {
        Ok(output) => to_json(&ImportResultJson {
            new: output.output.new.len(),
            updated: output.output.updated.len(),
            duplicate: output.output.duplicate.len(),
        }),
        Err(err) => {
            set_error(format!("could not import that file: {err}"));
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct StatsJson {
    /// Reviews per day; the key is days from today (0 = today, -1 = yesterday).
    reviews_per_day: std::collections::BTreeMap<i32, u32>,
    /// Seconds spent studying per day, same keys.
    seconds_per_day: std::collections::BTreeMap<i32, u32>,
    /// Per day: [new cards learned, forgotten cards relearned, reviews], same keys.
    breakdown_per_day: std::collections::BTreeMap<i32, [u32; 3]>,
    today_reviews: u32,
    today_seconds: u32,
    today_correct: u32,
    cards_new: u32,
    cards_learning: u32,
    cards_young: u32,
    cards_mature: u32,
    cards_suspended: u32,
    /// Share of reviews passed in the last month (0 to 1), if there were any.
    retention_month: Option<f32>,
    /// Cards coming due in each of the next days (key = days from today).
    due_ahead: std::collections::BTreeMap<i32, u32>,
    /// Review cards by interval in days.
    intervals: std::collections::BTreeMap<u32, u32>,
    /// Answers by hour of the day (0–23) over the last 3 months: [total, correct].
    hours: Vec<[u32; 2]>,
    /// How often each button (Again, Hard, Good, Easy) was pressed in the last 3 months,
    /// for learning, young and mature cards.
    buttons_learning: Vec<u32>,
    buttons_young: Vec<u32>,
    buttons_mature: Vec<u32>,
    /// Cards added per day (key = days from today, negative).
    added_per_day: std::collections::BTreeMap<i32, u32>,
    /// Passed / failed reviews for today, yesterday, week, month, year, all time:
    /// [young passed, young failed, mature passed, mature failed].
    true_retention: Vec<[u32; 4]>,
    /// Uses FSRS (memory strength) rather than the older scheduler.
    fsrs: bool,
    /// FSRS only: average chance of remembering a card right now (0–1).
    average_retrievability: Option<f32>,
}

/// Study history for the stats page, covering the last `days` days.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_stats(engine: *mut Engine, days: u32) -> *mut c_char {
    unsafe { stats_for(engine, days, String::new()) }
}

#[derive(serde::Deserialize)]
struct StatsRequest {
    days: u32,
    /// An Anki search to limit the stats to (e.g. one deck); empty = everything.
    #[serde(default)]
    search: String,
}

/// Like `study_stats`, limited to a search. JSON: `{days, search}`.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_stats_search(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    let Some(req) = (unsafe { str_arg(json) }).and_then(|j| serde_json::from_str::<StatsRequest>(j).ok()) else {
        set_error("the stats request was not readable");
        return std::ptr::null_mut();
    };
    unsafe { stats_for(engine, req.days, req.search) }
}

unsafe fn stats_for(engine: *mut Engine, days: u32, search: String) -> *mut c_char {
    use anki::services::StatsService;
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    let request = anki_proto::stats::GraphsRequest { search, days };
    let graphs = match inner.col.graphs(request) {
        Ok(graphs) => graphs,
        Err(err) => {
            set_error(format!("could not read stats: {err}"));
            return std::ptr::null_mut();
        }
    };
    let total = |r: &anki_proto::stats::graphs_response::review_counts_and_times::Reviews| {
        r.learn + r.relearn + r.young + r.mature + r.filtered
    };
    let reviews = graphs.reviews.unwrap_or_default();
    let today = graphs.today.unwrap_or_default();
    let counts = graphs
        .card_counts
        .and_then(|c| c.excluding_inactive)
        .unwrap_or_default();
    let suspended = graphs
        .card_counts
        .and_then(|c| c.including_inactive)
        .map(|c| c.suspended)
        .unwrap_or_default();
    let retention_rows = graphs
        .true_retention
        .map(|t| {
            [t.today, t.yesterday, t.week, t.month, t.year, t.all_time]
                .into_iter()
                .map(|r| {
                    let r = r.unwrap_or_default();
                    [r.young_passed, r.young_failed, r.mature_passed, r.mature_failed]
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let buttons = graphs.buttons.clone().and_then(|b| b.three_months).unwrap_or_default();
    let hours = graphs
        .hours
        .clone()
        .map(|h| h.three_months.iter().map(|x| [x.total, x.correct]).collect())
        .unwrap_or_default();
    let retention_month = graphs.true_retention.and_then(|t| t.month).and_then(|m| {
        let passed = m.young_passed + m.mature_passed;
        let all = passed + m.young_failed + m.mature_failed;
        (all > 0).then(|| passed as f32 / all as f32)
    });
    let stats = StatsJson {
        reviews_per_day: reviews.count.iter().map(|(day, r)| (*day, total(r))).collect(),
        seconds_per_day: reviews.time.iter().map(|(day, r)| (*day, total(r) / 1000)).collect(),
        breakdown_per_day: reviews
            .count
            .iter()
            .map(|(day, r)| (*day, [r.learn, r.relearn, r.young + r.mature + r.filtered]))
            .collect(),
        today_reviews: today.answer_count,
        today_seconds: today.answer_millis / 1000,
        today_correct: today.correct_count,
        cards_new: counts.new_cards,
        cards_learning: counts.learn + counts.relearn,
        cards_young: counts.young,
        cards_mature: counts.mature,
        cards_suspended: suspended,
        retention_month,
        due_ahead: graphs
            .future_due
            .map(|f| f.future_due.into_iter().filter(|(d, _)| (0..=30).contains(d)).collect())
            .unwrap_or_default(),
        intervals: graphs.intervals.map(|i| i.intervals.into_iter().collect()).unwrap_or_default(),
        hours,
        buttons_learning: buttons.learning,
        buttons_young: buttons.young,
        buttons_mature: buttons.mature,
        added_per_day: graphs.added.map(|a| a.added.into_iter().collect()).unwrap_or_default(),
        true_retention: retention_rows,
        fsrs: graphs.fsrs,
        average_retrievability: graphs
            .retrievability
            .filter(|_| graphs.fsrs)
            .map(|r| r.average / 100.0)
            .filter(|v| *v > 0.0),
    };
    to_json(&stats)
}

// ---------------------------------------------------------------------------
// Browsing and searching
// ---------------------------------------------------------------------------

/// Runs `f` with the open collection and its parsed JSON request, and returns
/// its answer as JSON. Saves repeating the same checks in every function below.
unsafe fn with_request<Req, Out>(
    engine: *mut Engine,
    json: *const c_char,
    f: impl FnOnce(&mut Inner, Req) -> Result<Out, String>,
) -> *mut c_char
where
    Req: serde::de::DeserializeOwned,
    Out: Serialize,
{
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let request = match unsafe { str_arg(json) }.map(serde_json::from_str::<Req>) {
        Some(Ok(request)) => request,
        Some(Err(err)) => {
            set_error(format!("the request was not readable: {err}"));
            return std::ptr::null_mut();
        }
        None => {
            set_error("the request was missing");
            return std::ptr::null_mut();
        }
    };
    let Some(mut inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    match f(&mut inner, request) {
        Ok(out) => to_json(&out),
        Err(message) => {
            set_error(message);
            std::ptr::null_mut()
        }
    }
}

/// The columns the Browse table shows, in order.
/// The "back" text is worked out here instead (see `back_text`), and goes second.
const BROWSE_COLUMNS: [&str; 8] = [
    "noteFld", "deck", "cardDue", "cardIvl", "cardEase", "note", "template", "noteCrt",
];

/// The answer side as one line of plain text, without the question repeated:
/// most card types show the question, then a divider, then the answer.
fn back_text(col: &mut Collection, card_id: CardId) -> String {
    let Ok(rendered) = col.render_existing_card(card_id, true, false) else {
        return String::new();
    };
    let answer = rendered.answer();
    let after_divider = answer
        .find("id=answer")
        .or_else(|| answer.find("id=\"answer\""))
        .and_then(|at| answer[at..].find('>').map(|end| &answer[at + end + 1..]))
        .unwrap_or(&answer);
    anki::text::html_to_text_line(after_divider, false).trim().to_string()
}

#[derive(serde::Deserialize)]
struct SearchRequest {
    /// Anki search text, e.g. `deck:Biology heart` or `is:due`. Empty = everything.
    query: String,
    /// A column name from `BROWSE_COLUMNS` (or "noteCrt" for date added).
    #[serde(default)]
    sort: Option<String>,
    #[serde(default)]
    reverse: bool,
    /// One row per note (its first card in the results) instead of per card.
    #[serde(default)]
    notes: bool,
}

/// Finds cards matching an Anki search. Returns a JSON list of card ids,
/// in the order asked for.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_search(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::browser_table::Column;
    use anki::search::SortMode;
    use std::str::FromStr;
    unsafe {
        with_request(engine, json, |inner, req: SearchRequest| {
            let mode = match req.sort.as_deref().map(Column::from_str) {
                Some(Ok(column)) => SortMode::Builtin { column, reverse: req.reverse },
                _ => SortMode::NoOrder,
            };
            let ids = inner
                .col
                .search_cards(req.query.as_str(), mode)
                .map_err(|e| friendly_search_error(&e))?;
            if req.notes {
                let mut seen = std::collections::HashSet::new();
                let mut kept = Vec::new();
                for id in ids {
                    if let Ok(Some(card)) = inner.col.storage.get_card(id) {
                        if seen.insert(card.note_id()) {
                            kept.push(id.0);
                        }
                    }
                }
                return Ok(kept);
            }
            Ok(ids.into_iter().map(|id| id.0).collect::<Vec<i64>>())
        })
    }
}

fn friendly_search_error(err: &anki::error::AnkiError) -> String {
    let tr = I18n::template_only();
    let detail = err.message(&tr);
    format!("Couldn't understand that search. {detail}")
}

#[derive(Serialize)]
struct BrowseRowJson {
    id: i64,
    note_id: i64,
    /// Text for each column: front, back, then the rest of `BROWSE_COLUMNS`.
    cells: Vec<String>,
    /// "new", "learning", "review", "suspended" or "buried".
    state: &'static str,
    /// 0 = none, 1 red, 2 orange, 3 green, 4 blue, 5 pink, 6 turquoise, 7 purple.
    flag: u8,
    marked: bool,
}

/// Table rows for the given card ids (a JSON list), in the same order.
/// Cards that no longer exist are left out.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_browse_rows(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::card::CardQueueNumber;
    use anki::config::BoolKey;
    use anki::services::SearchService;
    use anki_proto::search::browser_row::Color;
    unsafe {
        with_request(engine, json, |inner, ids: Vec<i64>| {
            let col = &mut inner.col;
            // The table is one row per card; Anki's "notes mode" would change that.
            if col.get_config_bool(BoolKey::BrowserTableShowNotesMode) {
                col.set_config_bool(BoolKey::BrowserTableShowNotesMode, false, false)
                    .map_err(|e| e.to_string())?;
            }
            SearchService::set_active_browser_columns(
                col,
                anki_proto::generic::StringList {
                    vals: BROWSE_COLUMNS.iter().map(|c| c.to_string()).collect(),
                },
            )
            .map_err(|e| e.to_string())?;
            let mut rows = Vec::with_capacity(ids.len());
            for id in ids {
                let Ok(Some(card)) = col.storage.get_card(CardId(id)) else { continue };
                let Ok(row) = col.browser_row_for_id(id) else { continue };
                let back = back_text(col, CardId(id));
                let color = Color::try_from(row.color).unwrap_or(Color::Default);
                let state = match color {
                    Color::Suspended => "suspended",
                    Color::Buried => "buried",
                    _ => match card.queue_number() {
                        CardQueueNumber::New => "new",
                        CardQueueNumber::Learning => "learning",
                        CardQueueNumber::Review => "review",
                        CardQueueNumber::Invalid => "suspended",
                    },
                };
                let flag = match color {
                    Color::FlagRed => 1,
                    Color::FlagOrange => 2,
                    Color::FlagGreen => 3,
                    Color::FlagBlue => 4,
                    Color::FlagPink => 5,
                    Color::FlagTurquoise => 6,
                    Color::FlagPurple => 7,
                    _ => 0,
                };
                rows.push(BrowseRowJson {
                    id,
                    note_id: card.note_id().0,
                    cells: {
                        let mut cells: Vec<String> = row.cells.into_iter().map(|c| c.text).collect();
                        cells.insert(1.min(cells.len()), back);
                        cells
                    },
                    state,
                    flag,
                    marked: color == Color::Marked,
                });
            }
            Ok(rows)
        })
    }
}

#[derive(Serialize)]
struct NoteJson {
    note_id: i64,
    card_id: i64,
    /// Which card of the note this is (0-based template / cloze number − 1).
    card_ordinal: u16,
    deck_id: i64,
    notetype_id: i64,
    notetype_name: String,
    is_cloze: bool,
    field_names: Vec<String>,
    fields: Vec<String>,
    tags: Vec<String>,
    /// The card, rendered, for the preview.
    question: String,
    answer: String,
    css: String,
}

/// Everything about the note behind a card (JSON: the card id as a number),
/// for the editor and preview in Browse.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_note_for_card(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::NotetypeKind;
    unsafe {
        with_request(engine, json, |inner, card_id: i64| {
            let col = &mut inner.col;
            let card = col
                .storage
                .get_card(CardId(card_id))
                .map_err(|e| e.to_string())?
                .ok_or("that card no longer exists")?;
            let note = col
                .storage
                .get_note(card.note_id())
                .map_err(|e| e.to_string())?
                .ok_or("that card's note no longer exists")?;
            let notetype = col
                .get_notetype(note.notetype_id)
                .map_err(|e| e.to_string())?
                .ok_or("that card type no longer exists")?;
            let tr = I18n::template_only();
            let (question, answer, css) = match col.render_existing_card(card.id(), false, false) {
                Ok(r) => (
                    prepare_side(&r.question(), true, &tr).0,
                    prepare_side(&r.answer(), false, &tr).0,
                    r.css,
                ),
                Err(err) => (err.message(&tr), String::new(), String::new()),
            };
            Ok(NoteJson {
                note_id: note.id.0,
                card_id,
                card_ordinal: card.template_idx(),
                deck_id: card.deck_id().0,
                notetype_id: notetype.id.0,
                notetype_name: notetype.name.clone(),
                is_cloze: notetype.config.kind() == NotetypeKind::Cloze,
                field_names: notetype.fields.iter().map(|f| f.name.clone()).collect(),
                fields: note.fields().clone(),
                tags: note.tags.clone(),
                question,
                answer,
                css,
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct UpdateNoteRequest {
    note_id: i64,
    fields: Vec<String>,
    tags: Vec<String>,
}

/// Saves edited fields and tags. Returns `true` as JSON. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_update_note(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notes::NoteId;
    unsafe {
        with_request(engine, json, |inner, req: UpdateNoteRequest| {
            inner.current = None;
            let col = &mut inner.col;
            let mut note = col
                .storage
                .get_note(NoteId(req.note_id))
                .map_err(|e| e.to_string())?
                .ok_or("that note no longer exists")?;
            let count = note.fields().len();
            for (index, value) in req.fields.into_iter().enumerate().take(count) {
                note.set_field(index, value).map_err(|e| e.to_string())?;
            }
            note.tags = req.tags;
            col.update_note(&mut note).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

#[derive(serde::Deserialize)]
struct CardsRequest {
    card_ids: Vec<i64>,
    /// For `study_set_suspended`.
    #[serde(default)]
    suspended: bool,
    /// For `study_set_deck`.
    #[serde(default)]
    deck_id: i64,
}

fn card_ids(req: &CardsRequest) -> Vec<CardId> {
    req.card_ids.iter().map(|&id| CardId(id)).collect()
}

/// Suspends (or brings back) cards. JSON: `{card_ids, suspended}`. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_set_suspended(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::scheduler::bury_or_suspend_cards_request::Mode;
    unsafe {
        with_request(engine, json, |inner, req: CardsRequest| {
            inner.current = None;
            let ids = card_ids(&req);
            if req.suspended {
                inner.col.bury_or_suspend_cards(&ids, Mode::Suspend).map(|_| ())
            } else {
                inner.col.unbury_or_unsuspend_cards(&ids).map(|_| ())
            }
            .map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

/// Moves cards to another deck. JSON: `{card_ids, deck_id}`. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_set_deck(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: CardsRequest| {
            inner.current = None;
            let ids = card_ids(&req);
            inner.col.set_deck(&ids, DeckId(req.deck_id)).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

/// Deletes the notes behind these cards (and so all their cards).
/// JSON: `{card_ids}`. Returns how many notes went. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_delete_notes(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: CardsRequest| {
            inner.current = None;
            let col = &mut inner.col;
            let mut note_ids = Vec::new();
            for id in card_ids(&req) {
                if let Ok(Some(card)) = col.storage.get_card(id) {
                    if !note_ids.contains(&card.note_id()) {
                        note_ids.push(card.note_id());
                    }
                }
            }
            let removed = col.remove_notes(&note_ids).map_err(|e| e.to_string())?;
            Ok(removed.output)
        })
    }
}

/// Makes a deck (and any parents) from a name like `Biology::Week 1`.
/// Returns its id; an existing deck with that name is reused.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_add_deck(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, name: String| {
            let name = name.trim();
            if name.is_empty() {
                return Err("the deck needs a name".to_string());
            }
            let deck = inner.col.get_or_create_normal_deck(name).map_err(|e| e.to_string())?;
            Ok(deck.id.0)
        })
    }
}

// ---------------------------------------------------------------------------
// Deck menu: rename, delete, export, options
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct DeckRequest {
    deck_id: i64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    path: String,
    #[serde(default)]
    with_scheduling: bool,
    #[serde(default)]
    with_media: bool,
}

/// Renames a deck. A name with "::" moves it under another deck. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_rename_deck(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: DeckRequest| {
            let name = req.name.trim();
            if name.is_empty() {
                return Err("the deck needs a name".to_string());
            }
            inner.col.rename_deck(DeckId(req.deck_id), name).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

/// Deletes a deck, its sections and all their cards. Returns how many cards went. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_delete_deck(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: DeckRequest| {
            inner.current = None;
            let out = inner
                .col
                .remove_decks_and_child_decks(&[DeckId(req.deck_id)])
                .map_err(|e| e.to_string())?;
            Ok(out.output)
        })
    }
}

/// Saves a deck (and its sections) as an .apkg file. Returns how many notes went in.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_export_deck(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::search::SearchNode;
    use anki_proto::import_export::ExportAnkiPackageOptions;
    unsafe {
        with_request(engine, json, |inner, req: DeckRequest| {
            let options = ExportAnkiPackageOptions {
                with_scheduling: req.with_scheduling,
                with_deck_configs: req.with_scheduling,
                with_media: req.with_media,
                legacy: false,
            };
            inner
                .col
                .export_apkg(&req.path, options, SearchNode::from_deck_id(DeckId(req.deck_id), true), None)
                .map_err(|e| format!("could not export: {e}"))
        })
    }
}

/// The settings on the deck Options screen, in plain units.
#[derive(Serialize, serde::Deserialize, Clone)]
struct DeckSettingsJson {
    new_per_day: u32,
    reviews_per_day: u32,
    /// Minutes.
    learn_steps: Vec<f32>,
    relearn_steps: Vec<f32>,
    /// Days.
    graduating_interval_good: u32,
    graduating_interval_easy: u32,
    maximum_review_interval: u32,
    /// e.g. 2.5
    initial_ease: f32,
    leech_threshold: u32,
    /// true = suspend leeches, false = only tag them.
    leech_suspend: bool,
    bury_new: bool,
    bury_reviews: bool,
    bury_interday_learning: bool,
    /// 0…1, used by FSRS.
    desired_retention: f32,
    /// true = new cards in random order, false = in the order added.
    new_random: bool,
}

#[derive(Serialize)]
struct PresetJson {
    id: i64,
    name: String,
    use_count: u32,
}

#[derive(Serialize)]
struct DeckOptionsJson {
    deck_name: String,
    preset_id: i64,
    presets: Vec<PresetJson>,
    fsrs: bool,
    settings: DeckSettingsJson,
}

fn settings_from(inner: &anki_proto::deck_config::deck_config::Config) -> DeckSettingsJson {
    use anki_proto::deck_config::deck_config::config::{LeechAction, NewCardInsertOrder};
    DeckSettingsJson {
        new_per_day: inner.new_per_day,
        reviews_per_day: inner.reviews_per_day,
        learn_steps: inner.learn_steps.clone(),
        relearn_steps: inner.relearn_steps.clone(),
        graduating_interval_good: inner.graduating_interval_good,
        graduating_interval_easy: inner.graduating_interval_easy,
        maximum_review_interval: inner.maximum_review_interval,
        initial_ease: inner.initial_ease,
        leech_threshold: inner.leech_threshold,
        leech_suspend: inner.leech_action() == LeechAction::Suspend,
        bury_new: inner.bury_new,
        bury_reviews: inner.bury_reviews,
        bury_interday_learning: inner.bury_interday_learning,
        desired_retention: inner.desired_retention,
        new_random: inner.new_card_insert_order() == NewCardInsertOrder::Random,
    }
}

/// Everything the deck Options screen needs. JSON: the deck id.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_deck_options(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::deckconfig::DeckConfigId;
    unsafe {
        with_request(engine, json, |inner, deck_id: i64| {
            let col = &mut inner.col;
            let info = col.get_deck_configs_for_update(DeckId(deck_id)).map_err(|e| e.to_string())?;
            let current = info.current_deck.ok_or("that deck has no options (is it a filtered deck?)")?;
            let config = col
                .get_deck_config(DeckConfigId(current.config_id), true)
                .map_err(|e| e.to_string())?
                .ok_or("deck options are missing")?;
            Ok(DeckOptionsJson {
                deck_name: current.name,
                preset_id: config.id.0,
                presets: info
                    .all_config
                    .iter()
                    .filter_map(|c| {
                        c.config.as_ref().map(|cfg| PresetJson { id: cfg.id, name: cfg.name.clone(), use_count: c.use_count })
                    })
                    .collect(),
                fsrs: info.fsrs,
                settings: settings_from(&config.inner),
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct SaveDeckOptionsRequest {
    deck_id: i64,
    /// The preset to save into (and use for this deck).
    preset_id: i64,
    /// Make a new preset with this name instead (e.g. to give a deck its own settings).
    #[serde(default)]
    new_preset_name: Option<String>,
    /// Leave the preset's settings as they are (just switch the deck to it).
    #[serde(default)]
    switch_only: bool,
    settings: DeckSettingsJson,
    fsrs: bool,
}

/// Saves the Options screen. Settings apply to the preset, and so to every
/// deck that uses it, the same as in Anki. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_save_deck_options(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::deckconfig::{DeckConfigId, UpdateDeckConfigsRequest};
    use anki_proto::deck_config::deck_config::config::{LeechAction, NewCardInsertOrder};
    use anki_proto::deck_config::UpdateDeckConfigsMode;
    unsafe {
        with_request(engine, json, |inner, req: SaveDeckOptionsRequest| {
            inner.current = None;
            let col = &mut inner.col;
            let info = col.get_deck_configs_for_update(DeckId(req.deck_id)).map_err(|e| e.to_string())?;
            let current = info.current_deck.ok_or("that deck has no options")?;
            let mut config = col
                .get_deck_config(DeckConfigId(req.preset_id), true)
                .map_err(|e| e.to_string())?
                .ok_or("deck options are missing")?;
            if let Some(name) = req.new_preset_name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                config.id = DeckConfigId(0);
                config.name = name.to_string();
            }
            if !req.switch_only {
                let s = &req.settings;
                let c = &mut config.inner;
                c.new_per_day = s.new_per_day;
                c.reviews_per_day = s.reviews_per_day;
                if !s.learn_steps.is_empty() {
                    c.learn_steps = s.learn_steps.clone();
                }
                c.relearn_steps = s.relearn_steps.clone();
                c.graduating_interval_good = s.graduating_interval_good.max(1);
                c.graduating_interval_easy = s.graduating_interval_easy.max(c.graduating_interval_good);
                c.maximum_review_interval = s.maximum_review_interval.max(1);
                c.initial_ease = s.initial_ease.clamp(1.31, 5.0);
                c.leech_threshold = s.leech_threshold.max(1);
                c.set_leech_action(if s.leech_suspend { LeechAction::Suspend } else { LeechAction::TagOnly });
                c.bury_new = s.bury_new;
                c.bury_reviews = s.bury_reviews;
                c.bury_interday_learning = s.bury_interday_learning;
                c.desired_retention = s.desired_retention.clamp(0.7, 0.99);
                c.set_new_card_insert_order(if s.new_random {
                    NewCardInsertOrder::Random
                } else {
                    NewCardInsertOrder::Due
                });
            }
            let request = UpdateDeckConfigsRequest {
                target_deck_id: DeckId(req.deck_id),
                configs: vec![config],
                removed_config_ids: vec![],
                mode: UpdateDeckConfigsMode::Normal,
                card_state_customizer: info.card_state_customizer,
                limits: current.limits.unwrap_or_default(),
                new_cards_ignore_review_limit: info.new_cards_ignore_review_limit,
                apply_all_parent_limits: info.apply_all_parent_limits,
                fsrs: req.fsrs,
                fsrs_reschedule: false,
                fsrs_health_check: info.fsrs_health_check,
            };
            col.update_deck_configs(request).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Filtered decks (temporary decks that borrow cards matching a search)
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct FilteredRequest {
    name: String,
    /// An Anki search, e.g. `rated:7:1` or `deck:"Biology" is:due`.
    search: String,
    limit: u32,
    /// "random", "due", "lapses", "added", "oldest_reviewed", "intervals".
    order: String,
    /// true = your answers count towards normal scheduling.
    reschedule: bool,
}

/// Makes a filtered deck and fills it. Returns its id, or an error such as
/// "no cards match". Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_create_filtered(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::services::DecksService;
    use anki_proto::decks::deck::filtered::search_term::Order;
    unsafe {
        with_request(engine, json, |inner, req: FilteredRequest| {
            inner.current = None;
            let col = &mut inner.col;
            // Start from Anki's defaults for a new filtered deck.
            let mut deck = DecksService::get_or_create_filtered_deck(col, anki_proto::decks::DeckId { did: 0 })
                .map_err(|e| e.to_string())?;
            let name = req.name.trim();
            if !name.is_empty() {
                deck.name = name.to_string();
            }
            let order = match req.order.as_str() {
                "random" => Order::Random,
                "due" => Order::Due,
                "lapses" => Order::Lapses,
                "added" => Order::Added,
                "intervals" => Order::IntervalsAscending,
                _ => Order::OldestReviewedFirst,
            };
            let mut config = deck.config.unwrap_or_default();
            config.reschedule = req.reschedule;
            config.search_terms = vec![anki_proto::decks::deck::filtered::SearchTerm {
                search: req.search.clone(),
                limit: req.limit.max(1),
                order: order as i32,
            }];
            deck.config = Some(config);
            deck.allow_empty = false;
            let out = DecksService::add_or_update_filtered_deck(col, deck).map_err(|e| {
                let tr = I18n::new(&["en"]);
                let message = e.message(&tr);
                if message.to_lowercase().contains("no cards") || message.to_lowercase().contains("did not match") {
                    "No cards match that. Try a different choice or a bigger range.".to_string()
                } else {
                    message
                }
            })?;
            Ok(out.id)
        })
    }
}

/// Refills a filtered deck from its search. Returns how many cards it holds.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_rebuild_filtered(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, deck_id: i64| {
            inner.current = None;
            let out = inner.col.rebuild_filtered_deck(DeckId(deck_id)).map_err(|e| e.to_string())?;
            Ok(out.output)
        })
    }
}

/// Sends every card in a filtered deck back to its own deck (the deck stays, empty).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_empty_filtered(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, deck_id: i64| {
            inner.current = None;
            inner.col.empty_filtered_deck(DeckId(deck_id)).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Preferences (collection-wide)
// ---------------------------------------------------------------------------

#[derive(Serialize, serde::Deserialize)]
struct PreferencesJson {
    /// Hour (0–23) when a new study day begins.
    next_day_starts_at: u32,
    /// Minutes: learning cards due within this are shown early when nothing else is left.
    learn_ahead_minutes: u32,
    /// "mix", "reviews_first" or "new_first".
    new_review_mix: String,
    /// Show learning cards from earlier days before reviews.
    day_learn_first: bool,
    show_intervals_on_buttons: bool,
    show_remaining_due_counts: bool,
    /// Minutes; 0 = no limit.
    time_limit_minutes: u32,
    /// Spread reviews evenly across days (FSRS).
    load_balancer: bool,
}

/// The collection-wide preferences, as JSON.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_preferences(engine: *mut Engine) -> *mut c_char {
    use anki_proto::config::preferences::scheduling::NewReviewMix;
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(inner) = engine.lock() else {
        return std::ptr::null_mut();
    };
    match inner.col.get_preferences() {
        Ok(prefs) => {
            let sched = prefs.scheduling.unwrap_or_default();
            let review = prefs.reviewing.unwrap_or_default();
            to_json(&PreferencesJson {
                next_day_starts_at: sched.rollover,
                learn_ahead_minutes: sched.learn_ahead_secs / 60,
                new_review_mix: match sched.new_review_mix() {
                    NewReviewMix::Distribute => "mix",
                    NewReviewMix::ReviewsFirst => "reviews_first",
                    NewReviewMix::NewFirst => "new_first",
                }
                .to_string(),
                day_learn_first: sched.day_learn_first,
                show_intervals_on_buttons: review.show_intervals_on_buttons,
                show_remaining_due_counts: review.show_remaining_due_counts,
                time_limit_minutes: review.time_limit_secs / 60,
                load_balancer: review.load_balancer_enabled,
            })
        }
        Err(err) => {
            set_error(format!("could not read preferences: {err}"));
            std::ptr::null_mut()
        }
    }
}

/// Saves the collection-wide preferences (JSON like `study_preferences` returns).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_set_preferences(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::config::preferences::scheduling::NewReviewMix;
    unsafe {
        with_request(engine, json, |inner, req: PreferencesJson| {
            inner.current = None;
            let col = &mut inner.col;
            let mut prefs = col.get_preferences().map_err(|e| e.to_string())?;
            let mut sched = prefs.scheduling.unwrap_or_default();
            sched.rollover = req.next_day_starts_at.min(23);
            sched.learn_ahead_secs = req.learn_ahead_minutes.min(24 * 60) * 60;
            sched.set_new_review_mix(match req.new_review_mix.as_str() {
                "reviews_first" => NewReviewMix::ReviewsFirst,
                "new_first" => NewReviewMix::NewFirst,
                _ => NewReviewMix::Distribute,
            });
            sched.day_learn_first = req.day_learn_first;
            let mut review = prefs.reviewing.unwrap_or_default();
            review.show_intervals_on_buttons = req.show_intervals_on_buttons;
            review.show_remaining_due_counts = req.show_remaining_due_counts;
            review.time_limit_secs = req.time_limit_minutes * 60;
            review.load_balancer_enabled = req.load_balancer;
            prefs.scheduling = Some(sched);
            prefs.reviewing = Some(review);
            col.set_preferences(prefs).map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Sync (AnkiWeb or a self-hosted sync server)
// ---------------------------------------------------------------------------

use anki::error::{AnkiError, NetworkErrorKind, SyncErrorKind};
use anki::sync::login::SyncAuth;

/// One background thread for network work, shared by all syncs.
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("could not start the network thread")
    })
}

fn web_client() -> reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    // Anki uses HTTP/1 only, as some servers don't support HTTP/2 proxies.
    CLIENT
        .get_or_init(|| reqwest::Client::builder().http1_only().build().expect("could not set up networking"))
        .clone()
}

/// Turns sync errors into something a student can act on.
fn sync_message(err: &AnkiError) -> String {
    match err {
        AnkiError::SyncError { source } => match source.kind {
            SyncErrorKind::AuthFailed => "That email or password wasn't right. Sign in again to keep syncing.".into(),
            SyncErrorKind::ClockIncorrect => "Your Mac's clock looks wrong. Fix the date and time in System Settings, then sync again.".into(),
            SyncErrorKind::ClientTooOld => "The sync server needs a newer version of the app.".into(),
            SyncErrorKind::UploadTooLarge => "Your collection is too big to upload to the server in one go.".into(),
            SyncErrorKind::ServerMessage => source.info.clone(),
            SyncErrorKind::ResyncRequired | SyncErrorKind::SanityCheckFailed { .. } => {
                "The server and this Mac disagree about your cards. Choose which copy to keep.".into()
            }
            _ => format!("Sync didn't finish: {}", source.info),
        },
        AnkiError::NetworkError { source } => match source.kind {
            NetworkErrorKind::Offline => "You seem to be offline. Check your internet connection.".into(),
            NetworkErrorKind::Timeout => "The sync server took too long to answer. Try again in a moment.".into(),
            _ => format!("Couldn't reach the sync server: {}", source.info),
        },
        AnkiError::Interrupted => "Sync was cancelled.".into(),
        other => format!("Sync didn't finish: {other}"),
    }
}

#[derive(serde::Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
    /// A self-hosted server's address; empty = AnkiWeb.
    #[serde(default)]
    endpoint: Option<String>,
}

#[derive(Serialize, serde::Deserialize)]
struct AuthJson {
    /// The sign-in key the server hands out (not the password).
    hkey: String,
    endpoint: Option<String>,
}

fn auth_from(json: &AuthJson) -> Result<SyncAuth, String> {
    anki_proto::sync::SyncAuth {
        hkey: json.hkey.clone(),
        endpoint: json.endpoint.clone().filter(|e| !e.trim().is_empty()),
        io_timeout_secs: None,
    }
    .try_into()
    .map_err(|e: AnkiError| format!("That server address doesn't look right: {e}"))
}

/// Signs in and returns a key to sync with. The password is not kept.
/// Needs no open collection.
///
/// # Safety
/// `json` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_sync_login(json: *const c_char) -> *mut c_char {
    let Some(request) = (unsafe { str_arg(json) }).and_then(|j| serde_json::from_str::<LoginRequest>(j).ok()) else {
        set_error("the sign-in details were not readable");
        return std::ptr::null_mut();
    };
    let endpoint = request.endpoint.clone().filter(|e| !e.trim().is_empty());
    let result = runtime().block_on(anki::sync::login::sync_login(
        request.username,
        request.password,
        endpoint.clone(),
        web_client(),
    ));
    match result {
        Ok(auth) => to_json(&AuthJson { hkey: auth.hkey, endpoint }),
        Err(err) => {
            set_error(sync_message(&err));
            std::ptr::null_mut()
        }
    }
}

#[derive(Serialize)]
struct SyncResultJson {
    /// "no_changes", "synced", or "full_sync" (a choice is needed: upload or download).
    result: &'static str,
    upload_ok: bool,
    download_ok: bool,
    server_message: String,
    /// The server moved; save this and use it from now on.
    new_endpoint: Option<String>,
}

/// A normal two-way sync of cards and progress (media is separate).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_sync(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::sync::collection::normal::SyncActionRequired;
    unsafe {
        with_request(engine, json, |inner, req: AuthJson| {
            inner.current = None;
            let auth = auth_from(&req)?;
            let output = runtime()
                .block_on(inner.col.normal_sync(auth, web_client()))
                .map_err(|e| sync_message(&e))?;
            let (result, upload_ok, download_ok) = match output.required {
                SyncActionRequired::NoChanges => ("no_changes", false, false),
                SyncActionRequired::NormalSyncRequired => ("synced", false, false),
                SyncActionRequired::FullSyncRequired { upload_ok, download_ok } => ("full_sync", upload_ok, download_ok),
            };
            Ok(SyncResultJson {
                result,
                upload_ok,
                download_ok,
                server_message: output.server_message,
                new_endpoint: output.new_endpoint,
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct FullSyncRequest {
    hkey: String,
    endpoint: Option<String>,
    /// true = replace the server's copy with this Mac's; false = replace this Mac's with the server's.
    upload: bool,
}

/// Replaces one side completely, when the two copies can't be merged.
/// The collection is closed for the transfer and reopened afterwards either way.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_full_sync(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: FullSyncRequest| {
            inner.current = None;
            let auth = auth_from(&AuthJson { hkey: req.hkey, endpoint: req.endpoint })?;
            let mut builder = inner.col.as_builder();
            // Swap in a throwaway in-memory collection while ours is handed to the sync.
            let placeholder = CollectionBuilder::new(PathBuf::from(":memory:"))
                .build()
                .map_err(|e| format!("could not prepare for the transfer: {e}"))?;
            let col = std::mem::replace(&mut inner.col, placeholder);
            let result = if req.upload {
                runtime().block_on(col.full_upload(auth, web_client()))
            } else {
                runtime().block_on(col.full_download(auth, web_client()))
            };
            // Reopen whatever is on disk now, whether or not the transfer worked.
            let reopened = builder.build().map_err(|e| format!("could not reopen your collection: {e}"))?;
            let placeholder = std::mem::replace(&mut inner.col, reopened);
            let _ = placeholder.close(None);
            result.map_err(|e| sync_message(&e))?;
            Ok(true)
        })
    }
}

/// Syncs pictures and sounds. Can take a while the first time; it only holds
/// the collection briefly at the start, so studying carries on meanwhile.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_sync_media(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error("collection is not open");
        return std::ptr::null_mut();
    };
    let Some(req) = (unsafe { str_arg(json) }).and_then(|j| serde_json::from_str::<AuthJson>(j).ok()) else {
        set_error("the sync details were not readable");
        return std::ptr::null_mut();
    };
    let auth = match auth_from(&req) {
        Ok(auth) => auth,
        Err(message) => {
            set_error(message);
            return std::ptr::null_mut();
        }
    };
    let (manager, progress) = {
        let Some(inner) = engine.lock() else { return std::ptr::null_mut() };
        match inner.col.media() {
            Ok(manager) => (manager, inner.col.new_progress_handler()),
            Err(err) => {
                set_error(format!("could not open the media folder: {err}"));
                return std::ptr::null_mut();
            }
        }
    };
    match runtime().block_on(manager.sync_media(progress, auth, web_client(), None)) {
        Ok(()) => to_json(&true),
        Err(err) => {
            set_error(sync_message(&err));
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Card actions (study screen and Browse)
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct CardActionRequest {
    /// "flag", "bury", "set_due" or "forget".
    action: String,
    card_ids: Vec<i64>,
    /// 0 = no flag, 1–7 = red … purple.
    #[serde(default)]
    flag: u32,
    /// Anki's due-date text: "0" = today, "1" = tomorrow, "3-7" = randomly 3 to 7 days.
    #[serde(default)]
    days: String,
}

/// Flag, bury, set due date or reset cards to new. Undoable.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_card_action(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::scheduler::bury_or_suspend_cards_request::Mode;
    unsafe {
        with_request(engine, json, |inner, req: CardActionRequest| {
            inner.current = None;
            let ids: Vec<CardId> = req.card_ids.iter().map(|&id| CardId(id)).collect();
            let col = &mut inner.col;
            let result = match req.action.as_str() {
                "flag" => col.set_card_flag(&ids, req.flag.min(7)).map(|_| ()),
                "bury" => col.bury_or_suspend_cards(&ids, Mode::BuryUser).map(|_| ()),
                "set_due" => col.set_due_date(&ids, req.days.trim(), None).map(|_| ()),
                "forget" => col.reschedule_cards_as_new(&ids, true, true, false, None).map(|_| ()),
                other => return Err(format!("unknown action “{other}”")),
            };
            result.map_err(|e| {
                let tr = I18n::new(&["en"]);
                e.message(&tr)
            })?;
            Ok(true)
        })
    }
}

#[derive(Serialize)]
struct CardInfoReview {
    /// Unix seconds.
    time: i64,
    /// "learn", "review", "relearn", "filtered", "manual" or "rescheduled".
    kind: &'static str,
    /// 1 Again, 2 Hard, 3 Good, 4 Easy (0 = manual change).
    button: u32,
    /// Days until next due, after this answer.
    interval_days: f32,
    seconds: f32,
}

#[derive(Serialize)]
struct CardInfoJson {
    deck: String,
    note_type: String,
    card_type: String,
    added: i64,
    first_review: Option<i64>,
    latest_review: Option<i64>,
    due_date: Option<i64>,
    due_position: Option<i32>,
    interval_days: u32,
    ease_percent: u32,
    reviews: u32,
    lapses: u32,
    average_seconds: f32,
    total_seconds: f32,
    /// FSRS: chance you'd remember it right now (0–1).
    retrievability: Option<f32>,
    /// FSRS: stability in days, difficulty 1–10.
    stability_days: Option<f32>,
    difficulty: Option<f32>,
    history: Vec<CardInfoReview>,
}

/// Everything Anki knows about one card (JSON: the card id).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_card_info(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::stats::revlog_entry::ReviewKind;
    unsafe {
        with_request(engine, json, |inner, card_id: i64| {
            let info = inner.col.card_stats(CardId(card_id)).map_err(|e| e.to_string())?;
            let history = info
                .revlog
                .iter()
                .map(|r| CardInfoReview {
                    time: r.time,
                    kind: match ReviewKind::try_from(r.review_kind).unwrap_or(ReviewKind::Review) {
                        ReviewKind::Learning => "learn",
                        ReviewKind::Review => "review",
                        ReviewKind::Relearning => "relearn",
                        ReviewKind::Filtered => "filtered",
                        ReviewKind::Manual => "manual",
                        ReviewKind::Rescheduled => "rescheduled",
                    },
                    button: r.button_chosen,
                    interval_days: r.interval as f32 / 86_400.0,
                    seconds: r.taken_secs,
                })
                .collect();
            Ok(CardInfoJson {
                deck: info.deck,
                note_type: info.notetype,
                card_type: info.card_type,
                added: info.added,
                first_review: info.first_review,
                latest_review: info.latest_review,
                due_date: info.due_date,
                due_position: info.due_position,
                interval_days: info.interval,
                ease_percent: info.ease / 10,
                reviews: info.reviews,
                lapses: info.lapses,
                average_seconds: info.average_secs,
                total_seconds: info.total_secs,
                retrievability: info.fsrs_retrievability,
                stability_days: info.memory_state.map(|m| m.stability),
                difficulty: info.memory_state.map(|m| m.difficulty),
                history,
            })
        })
    }
}

// ---------------------------------------------------------------------------
// Browse power tools
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct BulkRequest {
    /// "add_tags", "remove_tags", "find_replace", "reposition" or "change_type".
    action: String,
    card_ids: Vec<i64>,
    #[serde(default)]
    tags: String,
    #[serde(default)]
    find: String,
    #[serde(default)]
    replace: String,
    /// A field name to limit find & replace to; empty = all fields.
    #[serde(default)]
    field: String,
    /// Treat `find` as a regular expression.
    #[serde(default)]
    regex: bool,
    #[serde(default)]
    match_case: bool,
    #[serde(default)]
    start: u32,
    #[serde(default)]
    shift: bool,
    #[serde(default)]
    notetype_id: i64,
}

fn note_ids_of(col: &mut Collection, cards: &[i64]) -> Vec<NoteId> {
    let mut seen = std::collections::HashSet::new();
    cards
        .iter()
        .filter_map(|&id| col.storage.get_card(CardId(id)).ok().flatten())
        .map(|c| c.note_id())
        .filter(|nid| seen.insert(*nid))
        .collect()
}

fn escape_regex(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if "\\.+*?()|[]{}^$#&-~".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// Changes many cards at once. Returns how many notes or cards changed.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_bulk(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::NotetypeId;
    use anki::scheduler::new::NewCardDueOrder;
    unsafe {
        with_request(engine, json, |inner, req: BulkRequest| {
            inner.current = None;
            let tr = I18n::new(&["en"]);
            let nids = note_ids_of(&mut inner.col, &req.card_ids);
            let col = &mut inner.col;
            let changed = match req.action.as_str() {
                "add_tags" => col.add_tags_to_notes(&nids, req.tags.trim()).map(|o| o.output),
                "remove_tags" => col.remove_tags_from_notes(&nids, req.tags.trim()).map(|o| o.output),
                "find_replace" => {
                    let mut pattern = if req.regex { req.find.clone() } else { escape_regex(&req.find) };
                    if !req.match_case {
                        pattern = format!("(?i){pattern}");
                    }
                    let field = (!req.field.is_empty()).then(|| req.field.clone());
                    col.find_and_replace(nids, &pattern, &req.replace, field).map(|o| o.output)
                }
                "reposition" => {
                    let ids: Vec<CardId> = req.card_ids.iter().map(|&id| CardId(id)).collect();
                    col.sort_cards(&ids, req.start.max(1), 1, NewCardDueOrder::Preserve, req.shift)
                        .map(|o| o.output)
                }
                "change_type" => {
                    // Group by current card type; fields and card templates are matched by name, then position.
                    let mut by_type: std::collections::HashMap<NotetypeId, Vec<NoteId>> = Default::default();
                    for nid in &nids {
                        if let Ok(Some(note)) = col.storage.get_note(*nid) {
                            by_type.entry(note.notetype_id).or_default().push(*nid);
                        }
                    }
                    let target = NotetypeId(req.notetype_id);
                    let mut count = 0;
                    for (old, notes) in by_type {
                        if old == target {
                            continue;
                        }
                        let info = col.notetype_change_info(old, target).map_err(|e| e.message(&tr))?;
                        let mut input = info.input;
                        count += notes.len();
                        input.note_ids = notes;
                        col.change_notetype_of_notes(input).map_err(|e| e.message(&tr))?;
                    }
                    Ok(count)
                }
                other => return Err(format!("unknown action “{other}”")),
            };
            changed.map_err(|e| e.message(&tr))
        })
    }
}

#[derive(serde::Deserialize)]
struct DupesRequest {
    /// Which cards to look through (Anki search; empty = all).
    #[serde(default)]
    search: String,
}

#[derive(Serialize)]
struct DupeGroup {
    /// The repeated first field, as plain text.
    text: String,
    note_type: String,
    /// One card from each note, for opening them in Browse.
    card_ids: Vec<i64>,
    note_ids: Vec<i64>,
}

/// Notes whose first field is the same (ignoring formatting and case), within one card type.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_find_dupes(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::search::SortMode;
    unsafe {
        with_request(engine, json, |inner, req: DupesRequest| {
            let col = &mut inner.col;
            let cards = col
                .search_cards(req.search.as_str(), SortMode::NoOrder)
                .map_err(|e| friendly_search_error(&e))?;
            let mut first_card: std::collections::HashMap<NoteId, CardId> = Default::default();
            for cid in cards {
                if let Ok(Some(card)) = col.storage.get_card(cid) {
                    first_card.entry(card.note_id()).or_insert(cid);
                }
            }
            let mut groups: std::collections::HashMap<(i64, String), Vec<(NoteId, CardId)>> = Default::default();
            for (nid, cid) in &first_card {
                let Ok(Some(note)) = col.storage.get_note(*nid) else { continue };
                let Some(first) = note.fields().first() else { continue };
                let key = anki::text::strip_html_preserving_media_filenames(first)
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .to_lowercase();
                if key.is_empty() {
                    continue;
                }
                groups.entry((note.notetype_id.0, key)).or_default().push((*nid, *cid));
            }
            let mut names: std::collections::HashMap<i64, String> = Default::default();
            let mut out: Vec<DupeGroup> = Vec::new();
            for ((ntid, text), mut members) in groups {
                if members.len() < 2 {
                    continue;
                }
                members.sort();
                let note_type = names
                    .entry(ntid)
                    .or_insert_with(|| {
                        col.get_notetype(anki::notetype::NotetypeId(ntid))
                            .ok()
                            .flatten()
                            .map(|n| n.name.clone())
                            .unwrap_or_default()
                    })
                    .clone();
                out.push(DupeGroup {
                    text,
                    note_type,
                    card_ids: members.iter().map(|m| m.1 .0).collect(),
                    note_ids: members.iter().map(|m| m.0 .0).collect(),
                });
            }
            out.sort_by(|a, b| b.card_ids.len().cmp(&a.card_ids.len()).then(a.text.cmp(&b.text)));
            Ok(out)
        })
    }
}

/// Every tag in the collection, for suggestions.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_all_tags(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, _: serde_json::Value| {
            let tags = inner.col.storage.all_tags().map_err(|e| e.to_string())?;
            let mut names: Vec<String> = tags.into_iter().map(|t| t.name).collect();
            names.sort_by_key(|n| n.to_lowercase());
            Ok(names)
        })
    }
}

// ---------------------------------------------------------------------------
// Study more today
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct StudyMoreInfo {
    /// New cards / reviews beyond today's limits that could still be studied.
    extra_new: u32,
    extra_reviews: u32,
}

/// How many more cards a deck could give today if its limits were raised. JSON: deck id.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_more_info(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, deck_id: i64| {
            fn find(node: &anki_proto::decks::DeckTreeNode, id: i64) -> Option<&anki_proto::decks::DeckTreeNode> {
                if node.deck_id == id {
                    return Some(node);
                }
                node.children.iter().find_map(|c| find(c, id))
            }
            fn sum(node: &anki_proto::decks::DeckTreeNode, f: &dyn Fn(&anki_proto::decks::DeckTreeNode) -> u32) -> u32 {
                f(node) + node.children.iter().map(|c| sum(c, f)).sum::<u32>()
            }
            let tree = inner
                .col
                .deck_tree(Some(TimestampSecs::now()))
                .map_err(|e| e.to_string())?;
            let node = find(&tree, deck_id).ok_or("deck not found")?;
            // Everything waiting (ignoring limits) minus what today's limits already allow.
            let new_all = sum(node, &|n| n.new_uncapped);
            let review_all = sum(node, &|n| n.review_uncapped);
            Ok(StudyMoreInfo {
                extra_new: new_all.saturating_sub(node.new_count),
                extra_reviews: review_all.saturating_sub(node.review_count),
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct StudyMoreRequest {
    deck_id: i64,
    #[serde(default)]
    new_cards: i32,
    #[serde(default)]
    reviews: i32,
}

/// Raises today's limits for a deck (just for today), as Anki's Custom Study does.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_more(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::scheduler::custom_study_request::Value;
    unsafe {
        with_request(engine, json, |inner, req: StudyMoreRequest| {
            inner.current = None;
            let tr = I18n::new(&["en"]);
            for value in [
                (req.new_cards != 0).then_some(Value::NewLimitDelta(req.new_cards)),
                (req.reviews != 0).then_some(Value::ReviewLimitDelta(req.reviews)),
            ]
            .into_iter()
            .flatten()
            {
                inner
                    .col
                    .custom_study(anki_proto::scheduler::CustomStudyRequest { deck_id: req.deck_id, value: Some(value) })
                    .map_err(|e| e.message(&tr))?;
            }
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Housekeeping: check database / media, leeches, CSV import, full export
// ---------------------------------------------------------------------------

/// Finds and fixes problems in the collection (Anki's Check Database). Returns what it fixed.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_check_database(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::services::CollectionService;
    unsafe {
        with_request(engine, json, |inner, _: serde_json::Value| {
            inner.current = None;
            let out = CollectionService::check_database(&mut inner.col).map_err(|e| e.to_string())?;
            Ok(out.problems)
        })
    }
}

#[derive(Serialize)]
struct MediaCheckJson {
    /// Files in the media folder that no card uses.
    unused: Vec<String>,
    /// Files cards refer to that aren't in the folder.
    missing: Vec<String>,
    missing_notes: usize,
    missing_note_ids: Vec<i64>,
    renamed: usize,
    trash_count: u64,
    trash_bytes: u64,
}

/// Looks for unused and missing pictures and sounds (Anki's Check Media).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_check_media(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, _: serde_json::Value| {
            let mut checker = inner.col.media_checker().map_err(|e| e.to_string())?;
            let out = checker.check().map_err(|e| e.to_string())?;
            Ok(MediaCheckJson {
                unused: out.unused,
                missing: out.missing,
                missing_notes: out.missing_media_notes.len(),
                missing_note_ids: out.missing_media_notes.iter().map(|n| n.0).collect(),
                renamed: out.renamed.len(),
                trash_count: out.trash_count,
                trash_bytes: out.trash_bytes,
            })
        })
    }
}

/// Moves media files to the media trash (they can be restored until it's emptied).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_trash_media(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::services::MediaService;
    unsafe {
        with_request(engine, json, |inner, files: Vec<String>| {
            MediaService::trash_media_files(
                &mut inner.col,
                anki_proto::media::TrashMediaFilesRequest { fnames: files },
            )
            .map_err(|e| e.to_string())?;
            Ok(true)
        })
    }
}

#[derive(Serialize)]
struct LeechJson {
    leech: bool,
    suspended: bool,
    lapses: u32,
}

/// Whether a card is tagged "leech" (forgotten too many times), and suspended.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_leech_state(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, card_id: i64| {
            let card = inner
                .col
                .storage
                .get_card(CardId(card_id))
                .map_err(|e| e.to_string())?
                .ok_or("card not found")?;
            let proto = anki_proto::cards::Card::from(card.clone());
            let leech = inner
                .col
                .storage
                .get_note(card.note_id())
                .map_err(|e| e.to_string())?
                .map(|n| n.tags.iter().any(|t| t.eq_ignore_ascii_case("leech")))
                .unwrap_or(false);
            Ok(LeechJson { leech, suspended: proto.queue == -1, lapses: proto.lapses })
        })
    }
}

#[derive(serde::Deserialize)]
struct CsvRequest {
    path: String,
    #[serde(default)]
    deck_id: Option<i64>,
    #[serde(default)]
    notetype_id: Option<i64>,
    /// "update", "skip" or "duplicate", for notes whose first field already exists.
    #[serde(default)]
    duplicates: String,
}

#[derive(Serialize)]
struct CsvPreviewJson {
    /// First rows of the file, split into columns.
    preview: Vec<Vec<String>>,
    column_labels: Vec<String>,
    /// "tab", "comma", …
    delimiter: &'static str,
    notetype_id: i64,
    /// For each field of the card type, the column it comes from (1-based; 0 = none).
    field_columns: Vec<u32>,
    is_html: bool,
}

fn csv_metadata(inner: &mut Inner, req: &CsvRequest) -> Result<anki_proto::import_export::CsvMetadata, String> {
    use anki::notetype::NotetypeId;
    inner
        .col
        .get_csv_metadata(
            &req.path,
            None,
            req.notetype_id.map(NotetypeId),
            req.deck_id.map(DeckId),
            None,
        )
        .map_err(|e| {
            let tr = I18n::new(&["en"]);
            e.message(&tr)
        })
}

/// Reads the start of a text/CSV file and suggests how to import it.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_csv_preview(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::import_export::csv_metadata::{Delimiter, Notetype};
    unsafe {
        with_request(engine, json, |inner, req: CsvRequest| {
            let meta = csv_metadata(inner, &req)?;
            let (notetype_id, field_columns) = match &meta.notetype {
                Some(Notetype::GlobalNotetype(n)) => (n.id, n.field_columns.clone()),
                _ => (0, vec![]),
            };
            Ok(CsvPreviewJson {
                preview: meta.preview.iter().map(|row| row.vals.clone()).collect(),
                column_labels: meta.column_labels.clone(),
                delimiter: match Delimiter::try_from(meta.delimiter).unwrap_or(Delimiter::Comma) {
                    Delimiter::Tab => "tab",
                    Delimiter::Pipe => "pipe",
                    Delimiter::Semicolon => "semicolon",
                    Delimiter::Colon => "colon",
                    Delimiter::Comma => "comma",
                    Delimiter::Space => "space",
                },
                notetype_id,
                field_columns,
                is_html: meta.is_html,
            })
        })
    }
}

#[derive(Serialize)]
struct CsvImportJson {
    added: usize,
    updated: usize,
    skipped: usize,
    problems: usize,
}

/// Imports a text/CSV file into a deck with a card type (columns in field order).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_import_csv(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki_proto::import_export::csv_metadata::DupeResolution;
    unsafe {
        with_request(engine, json, |inner, req: CsvRequest| {
            inner.current = None;
            let mut meta = csv_metadata(inner, &req)?;
            meta.dupe_resolution = match req.duplicates.as_str() {
                "skip" => DupeResolution::Preserve,
                "duplicate" => DupeResolution::Duplicate,
                _ => DupeResolution::Update,
            } as i32;
            let out = inner.col.import_csv(&req.path, meta).map_err(|e| {
                let tr = I18n::new(&["en"]);
                e.message(&tr)
            })?;
            let log = out.output;
            Ok(CsvImportJson {
                added: log.new.len(),
                updated: log.updated.len(),
                skipped: log.duplicate.len() + log.first_field_match.len(),
                problems: log.conflicting.len()
                    + log.missing_notetype.len()
                    + log.missing_deck.len()
                    + log.empty_first_field.len(),
            })
        })
    }
}

#[derive(serde::Deserialize)]
struct ExportCollectionRequest {
    path: String,
    #[serde(default)]
    include_media: bool,
}

/// Saves the whole collection as a .colpkg (everything: decks, settings, progress, optionally media).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_export_collection(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: ExportCollectionRequest| {
            inner.current = None;
            let mut builder = inner.col.as_builder();
            let placeholder = CollectionBuilder::new(PathBuf::from(":memory:"))
                .build()
                .map_err(|e| format!("could not prepare the export: {e}"))?;
            let col = std::mem::replace(&mut inner.col, placeholder);
            let result = col.export_colpkg(&req.path, req.include_media, false);
            let reopened = builder.build().map_err(|e| format!("could not reopen your collection: {e}"))?;
            let placeholder = std::mem::replace(&mut inner.col, reopened);
            let _ = placeholder.close(None);
            result.map_err(|e| {
                let tr = I18n::new(&["en"]);
                e.message(&tr)
            })?;
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Card type editor
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct NotetypeSummary {
    id: i64,
    name: String,
    notes: u32,
    is_cloze: bool,
}

/// Every card type with how many notes use it.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`.
#[no_mangle]
pub unsafe extern "C" fn study_notetype_list(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::services::NotetypesService;
    unsafe {
        with_request(engine, json, |inner, _: serde_json::Value| {
            let counts = NotetypesService::get_notetype_names_and_counts(&mut inner.col).map_err(|e| e.to_string())?;
            let mut out = Vec::new();
            for entry in counts.entries {
                let is_cloze = inner
                    .col
                    .get_notetype(anki::notetype::NotetypeId(entry.id))
                    .ok()
                    .flatten()
                    .map(|n| n.config.kind() == anki::notetype::NotetypeKind::Cloze)
                    .unwrap_or(false);
                out.push(NotetypeSummary { id: entry.id, name: entry.name, notes: entry.use_count, is_cloze });
            }
            Ok(out)
        })
    }
}

#[derive(Serialize, serde::Deserialize)]
struct FieldSpec {
    /// The field's original position; None for a new field.
    ord: Option<u32>,
    name: String,
}

#[derive(Serialize, serde::Deserialize)]
struct TemplateSpec {
    ord: Option<u32>,
    name: String,
    front: String,
    back: String,
}

#[derive(Serialize, serde::Deserialize)]
struct NotetypeSpec {
    id: i64,
    name: String,
    #[serde(default)]
    is_cloze: bool,
    fields: Vec<FieldSpec>,
    templates: Vec<TemplateSpec>,
    css: String,
}

/// A card type's fields, card layouts and styling.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_notetype_get(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, id: i64| {
            let nt = inner
                .col
                .get_notetype(anki::notetype::NotetypeId(id))
                .map_err(|e| e.to_string())?
                .ok_or("that card type no longer exists")?;
            Ok(NotetypeSpec {
                id,
                name: nt.name.clone(),
                is_cloze: nt.config.kind() == anki::notetype::NotetypeKind::Cloze,
                fields: nt.fields.iter().map(|f| FieldSpec { ord: f.ord, name: f.name.clone() }).collect(),
                templates: nt
                    .templates
                    .iter()
                    .map(|t| TemplateSpec {
                        ord: t.ord,
                        name: t.name.clone(),
                        front: t.config.q_format.clone(),
                        back: t.config.a_format.clone(),
                    })
                    .collect(),
                css: nt.config.css.clone(),
            })
        })
    }
}

/// Saves a card type: renamed, added, removed or reordered fields and cards, new layouts and styling.
/// Fields keep their text by their original position (`ord`).
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_notetype_save(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::{CardTemplate, NoteField, NotetypeId};
    unsafe {
        with_request(engine, json, |inner, spec: NotetypeSpec| {
            inner.current = None;
            let tr = I18n::new(&["en"]);
            let original = inner
                .col
                .get_notetype(NotetypeId(spec.id))
                .map_err(|e| e.to_string())?
                .ok_or("that card type no longer exists")?;
            let mut nt = (*original).clone();
            nt.name = spec.name.trim().to_string();
            // Fields: keep existing ones (with their settings) by ord, add new ones.
            let mut fields = Vec::new();
            for f in spec.fields {
                let mut field = f
                    .ord
                    .and_then(|ord| original.fields.iter().find(|x| x.ord == Some(ord)).cloned())
                    .unwrap_or_else(|| NoteField::new(f.name.clone()));
                field.name = f.name.trim().to_string();
                fields.push(field);
            }
            nt.fields = fields;
            let mut templates = Vec::new();
            for t in spec.templates {
                let mut template = t
                    .ord
                    .and_then(|ord| original.templates.iter().find(|x| x.ord == Some(ord)).cloned())
                    .unwrap_or_else(|| CardTemplate::new(t.name.clone(), "", ""));
                template.name = t.name.trim().to_string();
                template.config.q_format = t.front;
                template.config.a_format = t.back;
                templates.push(template);
            }
            nt.templates = templates;
            nt.config.css = spec.css;
            inner.col.update_notetype(&mut nt, false).map_err(|e| e.message(&tr))?;
            Ok(true)
        })
    }
}

#[derive(serde::Deserialize)]
struct CopyNotetypeRequest {
    id: i64,
    name: String,
}

/// Makes a new card type as a copy of another (with no notes). Returns its id.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_notetype_copy(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    use anki::notetype::NotetypeId;
    unsafe {
        with_request(engine, json, |inner, req: CopyNotetypeRequest| {
            let tr = I18n::new(&["en"]);
            let original = inner
                .col
                .get_notetype(NotetypeId(req.id))
                .map_err(|e| e.to_string())?
                .ok_or("that card type no longer exists")?;
            let mut nt = (*original).clone();
            nt.id = NotetypeId(0);
            nt.name = req.name.trim().to_string();
            for f in nt.fields.iter_mut() {
                f.ord = None;
            }
            for t in nt.templates.iter_mut() {
                t.ord = None;
            }
            inner.col.add_notetype(&mut nt, false).map_err(|e| e.message(&tr))?;
            Ok(nt.id.0)
        })
    }
}

/// Deletes a card type and every note that uses it.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_notetype_delete(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, id: i64| {
            inner.current = None;
            let tr = I18n::new(&["en"]);
            inner
                .col
                .remove_notetype(anki::notetype::NotetypeId(id))
                .map_err(|e| e.message(&tr))?;
            Ok(true)
        })
    }
}

// ---------------------------------------------------------------------------
// Backups
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct BackupRequest {
    folder: String,
    /// Back up even if one was made recently.
    #[serde(default)]
    force: bool,
}

/// Saves a backup (.colpkg) into `folder` if the collection changed and none
/// was made in the last 30 minutes (or `force`). Old backups are thinned to
/// daily, weekly and monthly ones. Returns true if a backup was made.
///
/// # Safety
/// `engine` must be a live pointer from `study_open`; `json` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_backup(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    unsafe {
        with_request(engine, json, |inner, req: BackupRequest| {
            std::fs::create_dir_all(&req.folder).map_err(|e| format!("could not make the backup folder: {e}"))?;
            match inner.col.maybe_backup(PathBuf::from(&req.folder), req.force) {
                Ok(Some(handle)) => {
                    handle
                        .join()
                        .map_err(|_| "the backup stopped unexpectedly".to_string())?
                        .map_err(|e| format!("could not save the backup: {e}"))?;
                    Ok(true)
                }
                Ok(None) => Ok(false),
                Err(e) => Err(format!("could not back up: {e}")),
            }
        })
    }
}

#[derive(serde::Deserialize)]
struct RestoreRequest {
    backup: String,
    collection: String,
    media_folder: String,
    media_db: String,
}

/// Replaces a (closed) collection with a backup. Needs no open collection.
///
/// # Safety
/// `json` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn study_restore_backup(json: *const c_char) -> *mut c_char {
    let Some(req) = (unsafe { str_arg(json) }).and_then(|j| serde_json::from_str::<RestoreRequest>(j).ok()) else {
        set_error("the restore request was not readable");
        return std::ptr::null_mut();
    };
    let result = (|| -> Result<(), String> {
        // A throwaway collection just to get a progress handler.
        let scratch = CollectionBuilder::new(PathBuf::from(":memory:")).build().map_err(|e| e.to_string())?;
        let progress = scratch.new_progress_handler();
        anki::import_export::package::import_colpkg(
            &req.backup,
            &req.collection,
            std::path::Path::new(&req.media_folder),
            std::path::Path::new(&req.media_db),
            progress,
        )
        .map_err(|e| format!("could not restore that backup: {e}"))
    })();
    match result {
        Ok(()) => to_json(&true),
        Err(message) => {
            set_error(message);
            std::ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Errors and memory
// ---------------------------------------------------------------------------

/// The most recent error on this thread, or null if there was none.
/// The caller must free the result with `study_free_string`.
#[no_mangle]
pub extern "C" fn study_last_error() -> *mut c_char {
    LAST_ERROR.with(|e| match e.borrow_mut().take() {
        Some(msg) => to_c_string(msg),
        None => std::ptr::null_mut(),
    })
}

/// Free a string that this library returned.
///
/// # Safety
/// `s` must come from this library and must not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn study_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
