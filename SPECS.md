# dtMediaWiki specifications

> This document is the source of truth for dtMediaWiki's behavior, data model, and architecture. Update it whenever introducing a new feature, syntax token, setting, or architectural shift. Keep it concise, behavioral, and accurate.

---

## 1. Architecture

dtMediaWiki is a darktable plugin (Lua 5.4) for browsing and uploading images to Wikimedia Commons.

### 1.1. Layout

*   **`dtMediaWiki.lua`** — entry point. Registers the plugin, preferences, the "Wikimedia Commons" storage target, the export dialog, and the per-image metadata editor. `local version = N` is auto-bumped by `.git/hooks/pre-commit` (commit count + 1); do not edit it by hand.
*   **`lib/mediawikiapi.lua`** — MediaWiki API backend: curl-based HTTPS, session handling (ClientLogin with continuations), multipart uploads. Independent of darktable (needs only curl and dkjson).
*   **`lib/metadata_ui.lua`** — per-image Commons metadata editor UI (localized descriptions, templates, categories, Wikidata, other versions, extra fields). The categories field is a read-only view (union across the current selection); categories are changed only through the incremental Add / Remove entries, which attach or detach a single tag at a time (merge-safe, never a replace-all write). A ↻ refresh button re-saves pending edits and re-reads the library (same handler as "Save metadata"); it is the only way to pick up tag changes made elsewhere, since darktable exposes no tag-changed signal to Lua. All other fields are written back to the library only when their widget text differs from the value they were populated with on refresh (baseline guard); unedited widgets may be stale (e.g. after tags were changed in the native tag editor) and writing them back would silently replace the library values.
*   **`lib/category_search.lua`** — lighttable module that searches Commons categories and adds a result to the selected images (via `placeholders.add_category`, a single tag attach rather than a read-modify-write of the whole category list).
*   **`lib/placeholders.lua`** — registry and expansion engine for filename-pattern placeholders. Also owns the single-tag category helpers `add_category` / `remove_category` (attach/detach one category in the configured tag format, normalizing between the `[[Category:...]]` and plain-name forms).
*   **`lib/presets.lua`** — named metadata presets: save and apply.
*   **`lib/i18n.lua`** — gettext binding used by the lib/ modules (see §2).
*   **`lib/dkjson.lua`** — bundled third-party JSON module (David Kolf).
*   **`tests/test_categories.lua`** — standalone Lua tests for the category-tag helpers (no test framework).
*   **`tests/test_metadata_ui.lua`** — standalone Lua tests for the metadata editor's baseline guard and incremental category operations (no test framework).

### 1.2. Runtime

*   darktable embeds Lua 5.4; the plugin must stay 5.4-compatible (see §3).
*   Catalogs are loaded from `~/.config/darktable/lua/contrib/dtMediaWiki/locale/`, so translations only work when the plugin is installed in the darktable configuration directory.
*   Packaging: `dtmediawiki-dev-1.rockspec` (luarocks) with an explicit module list.

---

## 2. Translations

The UI is translated with gettext. There are **two wrapper forms**, and tooling must handle both:

*   **lib/ modules:**

    ```lua
    local i18n = require "contrib/dtMediaWiki/lib/i18n"
    local _ = i18n.translate
    -- ...
    _("Some user-visible string")
    ```

*   **`dtMediaWiki.lua`:** defines its own local `translate(msgid)` (wrapping `dt.gettext.dgettext`) and calls `translate("...")`.

Catalog layout: `locale/dtMediaWiki.pot` (template), `locale/<lang>/LC_MESSAGES/dtMediaWiki.po` (translations), `*.mo` (compiled).

### 2.1. Rules

1.  Wrap new user-visible strings (labels, tooltips, buttons, errors, and messages emitted via `msgout`/`dbgout`). Do not wrap strings sent to the API or internal identifiers.
2.  After adding, changing, or removing any wrapped string, run `python3 tools/update-translations.py`. It regenerates the `.pot`, updates every `.po` (existing translations are preserved verbatim), and recompiles the `.mo`. Commit the `locale/` changes in the same commit as the code change.
3.  Never hand-edit `.pot`, `.po`, or `.mo` files. Translators work through Transifex (`.tx/config`, project `simon04/dtmediawiki`).
4.  Changing the text of an existing string invalidates its translation: the new msgid appears with an empty `msgstr` until it is retranslated. That is expected, not an error.
5.  `python3 tools/update-translations.py --check` verifies synchronization (exit 1 if out of sync); CI runs it.

### 2.2. Why a custom script

`xgettext` cannot parse Lua: it misses strings, and it splits `_("a" .. "b")` concatenations into fragment msgids that are dead at runtime (the runtime looks up the joined string). `msgmerge` 1.0 in the build environments does not add new msgids. `tools/update-translations.py` handles extraction (both wrapper forms, concatenation joining, comment stripping), merging, and compilation deterministically; a no-op run produces byte-identical files.

---

## 3. Tooling and CI

*   The code must run on both Lua 5.4 (which darktable embeds) and Lua 5.5. Syntax that is valid in 5.4 but not in 5.5 must not be used — in particular, generic-for loop variables are const in 5.5, so never assign to them (use a separate local).
*   CI (`.github/workflows/ci.yml`, Lua 5.4 pinned) runs, in order: `luarocks make`, `luarocks install luacheck`, `luac -p *.lua lib/*.lua tests/*.lua`, `luacheck *.lua lib tests`, `python3 tools/update-translations.py --check`, `lua tests/test_categories.lua`, `lua tests/test_metadata_ui.lua`.
*   When checking locally, run both `luac5.4 -p` and `luac -p` (Lua 5.5) over `*.lua lib/*.lua tests/*.lua` to catch version-specific regressions.
