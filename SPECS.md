# dtMediaWiki specifications

> This document is the source of truth for dtMediaWiki's behavior, data model, and architecture. Update it whenever introducing a new feature, syntax token, setting, or architectural shift. Keep it concise, behavioral, and accurate.

---

## 1. Architecture

dtMediaWiki is a darktable plugin (Lua 5.4) for browsing and uploading images to Wikimedia Commons.

### 1.1. Layout

*   **`dtMediaWiki.lua`** — entry point. Registers the plugin, preferences, the "Wikimedia Commons" storage target, the export dialog, and the per-image metadata editor. `local version = N` is auto-bumped by `.git/hooks/pre-commit` (commit count + 1); do not edit it by hand.
*   **`lib/mediawikiapi.lua`** — MediaWiki API backend: curl-based HTTPS, session handling (ClientLogin with continuations), multipart uploads. Independent of darktable (needs only curl and dkjson).
*   **`lib/metadata_ui.lua`** — per-image Commons metadata editor UI (localized descriptions, templates, categories, Wikidata, other versions, extra fields).
*   **`lib/category_search.lua`** — lighttable module that searches Commons categories and adds a result to the selected images.
*   **`lib/placeholders.lua`** — registry and expansion engine for filename-pattern placeholders.
*   **`lib/presets.lua`** — named metadata presets: save and apply.
*   **`lib/i18n.lua`** — gettext binding used by the lib/ modules (see §2).
*   **`lib/dkjson.lua`** — bundled third-party JSON module (David Kolf).
*   **`tests/test_categories.lua`** — standalone Lua tests (no test framework).

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

*   Use the Lua 5.4 toolchain (`luac5.4`, `lua5.4`). A local Lua 5.5 rejects valid 5.4 code — e.g. `luac -p lib/metadata_ui.lua` fails at line 264 ("attempt to assign to const variable 'value'") because Lua 5.5 made generic-for iteration variables const.
*   CI (`.github/workflows/ci.yml`, Lua 5.4 pinned) runs, in order: `luarocks make`, `luarocks install luacheck`, `luac -p *.lua lib/*.lua tests/*.lua`, `luacheck *.lua lib tests`, `python3 tools/update-translations.py --check`, `lua tests/test_categories.lua`.
