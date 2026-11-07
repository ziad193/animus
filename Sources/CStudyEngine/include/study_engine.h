// The C functions exported by engine/src/lib.rs. Keep the two files in sync.
#ifndef STUDY_ENGINE_H
#define STUDY_ENGINE_H

typedef struct Engine Engine;

Engine *study_open(const char *path);
void study_close(Engine *engine);
char *study_deck_tree(Engine *engine);

#include <stdbool.h>
#include <stdint.h>
bool study_select_deck(Engine *engine, int64_t deck_id);
char *study_next_card(Engine *engine);
bool study_answer(Engine *engine, uint8_t rating, uint32_t milliseconds);
bool study_undo(Engine *engine);
char *study_stats(Engine *engine, uint32_t days);
char *study_stats_search(Engine *engine, const char *json);
char *study_notetypes(Engine *engine);
char *study_add_note(Engine *engine, const char *json);
char *study_add_stock_notetype(Engine *engine, const char *json);
char *study_import_apkg(Engine *engine, const char *path);
// Browse: each takes a JSON request and returns JSON (null on failure).
char *study_search(Engine *engine, const char *json);
char *study_browse_rows(Engine *engine, const char *json);
char *study_note_for_card(Engine *engine, const char *json);
char *study_update_note(Engine *engine, const char *json);
char *study_set_suspended(Engine *engine, const char *json);
char *study_set_deck(Engine *engine, const char *json);
char *study_delete_notes(Engine *engine, const char *json);
char *study_add_deck(Engine *engine, const char *json);
// Deck menu and preferences.
char *study_rename_deck(Engine *engine, const char *json);
char *study_delete_deck(Engine *engine, const char *json);
char *study_export_deck(Engine *engine, const char *json);
char *study_deck_options(Engine *engine, const char *json);
char *study_save_deck_options(Engine *engine, const char *json);
char *study_create_filtered(Engine *engine, const char *json);
char *study_rebuild_filtered(Engine *engine, const char *json);
char *study_empty_filtered(Engine *engine, const char *json);
char *study_preferences(Engine *engine);
char *study_set_preferences(Engine *engine, const char *json);
// Sync.
char *study_sync_login(const char *json);
char *study_sync(Engine *engine, const char *json);
char *study_full_sync(Engine *engine, const char *json);
char *study_sync_media(Engine *engine, const char *json);
// Checks a note before adding (duplicates etc.).
char *study_check_note(Engine *engine, const char *json);
// Image occlusion.
char *study_update_occlusion(Engine *engine, const char *json);
char *study_add_occlusion(Engine *engine, const char *json);
// Browse power tools.
char *study_bulk(Engine *engine, const char *json);
char *study_find_dupes(Engine *engine, const char *json);
char *study_typed_answer(Engine *engine, const char *json);
char *study_empty_cards(Engine *engine);
char *study_remove_cards(Engine *engine, const char *json);
char *study_rename_tag(Engine *engine, const char *json);
char *study_delete_tag(Engine *engine, const char *json);
char *study_clear_unused_tags(Engine *engine);
char *study_saved_searches(Engine *engine);
char *study_set_saved_searches(Engine *engine, const char *json);
char *study_deck_description(Engine *engine, const char *json);
char *study_all_tags(Engine *engine, const char *json);
// Study more today.
char *study_more_info(Engine *engine, const char *json);
char *study_more(Engine *engine, const char *json);
// Housekeeping.
char *study_check_database(Engine *engine, const char *json);
char *study_check_media(Engine *engine, const char *json);
char *study_trash_media(Engine *engine, const char *json);
char *study_leech_state(Engine *engine, const char *json);
char *study_csv_preview(Engine *engine, const char *json);
char *study_import_csv(Engine *engine, const char *json);
char *study_export_collection(Engine *engine, const char *json);
// Card type editor.
char *study_notetype_list(Engine *engine, const char *json);
char *study_notetype_get(Engine *engine, const char *json);
char *study_notetype_save(Engine *engine, const char *json);
char *study_notetype_copy(Engine *engine, const char *json);
char *study_notetype_delete(Engine *engine, const char *json);
// Card actions.
char *study_card_action(Engine *engine, const char *json);
char *study_card_info(Engine *engine, const char *json);
// Backups.
char *study_backup(Engine *engine, const char *json);
char *study_restore_backup(const char *json);
char *study_fsrs_optimize(Engine *engine, const char *json);
char *study_undo_status(Engine *engine, const char *json);
char *study_redo(Engine *engine, const char *json);
char *study_media_progress(Engine *engine, const char *json);
char *study_last_error(void);
void study_free_string(char *s);

#endif
