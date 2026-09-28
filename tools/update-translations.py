#!/usr/bin/env python3
"""Regenerate the dtMediaWiki translation catalogs from the Lua source.

The plugin translates its user interface with gettext. Every translatable
string is a call to the translation function: ``_("...")`` in lib/ (see
lib/i18n.lua) and ``translate("...")`` in dtMediaWiki.lua. The translation
catalogs live under ``locale/``:

  locale/dtMediaWiki.pot            template, one msgid per translatable string
  locale/<lang>/LC_MESSAGES/...po   per-language translations
  locale/<lang>/LC_MESSAGES/...mo   compiled binary catalogs (runtime)

This script is the ONLY way to maintain those files. Do not edit the
.pot/.po/.mo files by hand.

Usage:
  tools/update-translations.py            regenerate .pot, update .po, compile .mo
  tools/update-translations.py --check    verify catalogs match the source (CI)

Typical workflow after adding or changing a ``_("...")`` string:
  1. edit the Lua source
  2. run:  tools/update-translations.py
  3. commit the Lua change together with the locale/ changes
"""

import argparse
import glob
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCALE_DIR = os.path.join(ROOT, "locale")
POT_PATH = os.path.join(LOCALE_DIR, "dtMediaWiki.pot")
DOMAIN = "dtMediaWiki"

# Third-party Lua that is not part of the plugin UI and must not be scanned.
EXCLUDE_BASENAMES = {"dkjson.lua"}

WRAP_WIDTH = 76


# ---------------------------------------------------------------------------
# Source discovery and string extraction
# ---------------------------------------------------------------------------

def lua_files():
    """Return the plugin Lua source files to scan, in a stable order."""
    files = glob.glob(os.path.join(ROOT, "*.lua"))
    files += glob.glob(os.path.join(ROOT, "lib", "*.lua"))
    files = [
        f for f in files
        if os.path.basename(f) not in EXCLUDE_BASENAMES
    ]
    return sorted(set(files))


def _lua_string_at(text, i):
    """If text[i] opens a Lua string literal, return (value, index_after).

    Handles both quote styles and backslash escapes. Returns (None, i) if
    text[i] is not a quote.
    """
    if i >= len(text) or text[i] not in ('"', "'"):
        return None, i
    quote = text[i]
    j = i + 1
    out = []
    while j < len(text):
        c = text[j]
        if c == "\\" and j + 1 < len(text):
            out.append(_unescape(text[j:j + 2]))
            j += 2
        elif c == quote:
            j += 1
            break
        else:
            out.append(c)
            j += 1
    return "".join(out), j


def _unescape(seq):
    """Unescape a two-character backslash sequence such as ``\\n`` or ``\\"``."""
    simple = {"n": "\n", "t": "\t", "r": "\r"}
    if len(seq) == 2 and seq[0] == "\\":
        return simple.get(seq[1], seq[1])
    return seq


def _strip_comments(text):
    """Return text with Lua comments replaced by spaces.

    Offsets and newlines are preserved so that character positions and
    line numbers computed on the result match the original file. Handles
    ``--`` line comments and ``--[[ ... ]]`` block comments while
    respecting string literals (both quote styles, backslash escapes).
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in ('"', "'"):
            j = i + 1
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    j += 2
                elif text[j] == c:
                    j += 1
                    break
                else:
                    j += 1
            i = j
        elif c == "-" and text.startswith("--", i):
            if text.startswith("--[[", i):
                end = text.find("]]", i + 4)
                j = n if end == -1 else end + 2
            else:
                end = text.find("\n", i)
                j = n if end == -1 else end
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def extract_strings(path):
    """Yield (msgid, line) for every translation call in the file.

    Recognizes ``_("...")`` and ``translate("...")``. Concatenated
    literals (``_("a" .. "b")``) are joined into a single msgid. Comments
    are ignored.
    """
    with open(path, encoding="utf-8") as f:
        text = _strip_comments(f.read())

    for m in re.finditer(r"(?<![\w_])(?:_|translate)\(", text):
        start = m.start()
        i = m.end()
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        value, i = _lua_string_at(text, i)
        if value is None:
            continue
        parts = [value]
        while True:
            k = i
            while k < len(text) and text[k] in " \t\r\n":
                k += 1
            if not text.startswith("..", k):
                break
            k += 2
            while k < len(text) and text[k] in " \t\r\n":
                k += 1
            value2, k = _lua_string_at(text, k)
            if value2 is None:
                break
            parts.append(value2)
            i = k
        line = text.count("\n", 0, start) + 1
        yield "".join(parts), line


def collect_entries():
    """Return an ordered list of (msgid, [relative_locations]).

    Order follows the source (file order, then line order). Repeated msgids
    accumulate all of their locations.
    """
    order = []
    index = {}
    for path in lua_files():
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        for msgid, line in extract_strings(path):
            if msgid not in index:
                index[msgid] = []
                order.append(msgid)
            index[msgid].append("%s:%d" % (rel, line))
    return [(msgid, index[msgid]) for msgid in order]


# ---------------------------------------------------------------------------
# .pot / .po formatting
# ---------------------------------------------------------------------------

def _escape(value):
    return (
        value.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("\n", "\\n")
             .replace("\t", "\\t")
             .replace("\r", "\\r")
    )


def _wrap(value, width):
    """Wrap a string at word boundaries into lines of at most `width`."""
    if len(value) <= width:
        return [value]
    # Preserve leading whitespace: gettext msgids are matched byte-for-byte,
    # and some source strings intentionally start with a space.
    leading = len(value) - len(value.lstrip(" "))
    body = value[leading:]
    lines = []
    current = ""
    for word in body.split(" "):
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= width:
            current += " " + word
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    if not lines:
        return [value]
    lines[0] = " " * leading + lines[0]
    return lines


def _quoted_lines(value):
    """Format a (possibly long) string as one or more quoted .po lines."""
    if "\n" in value or len(value) > WRAP_WIDTH:
        lines = _wrap(value, WRAP_WIDTH)
        out = []
        for i, line in enumerate(lines):
            if i < len(lines) - 1:
                out.append('"%s "' % _escape(line))
            else:
                out.append('"%s"' % _escape(line))
        return out
    return ['"%s"' % _escape(value)]


def _entry(msgid, locations, msgstr):
    lines = []
    for loc in locations:
        lines.append("#: %s" % loc)
    if msgid == "":
        lines.append('msgid ""')
    else:
        lines.append("msgid " + _quoted_lines(msgid)[0])
        lines.extend(_quoted_lines(msgid)[1:])
    if msgstr == "":
        lines.append('msgstr ""')
    else:
        lines.append("msgstr " + _quoted_lines(msgstr)[0])
        lines.extend(_quoted_lines(msgstr)[1:])
    return "\n".join(lines)


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M+0000")


def _pot_header(date):
    return (
        "# dtMediaWiki translation template.\n"
        "# Generated by tools/update-translations.py -- do not edit by hand.\n"
        "#\n"
        '#, fuzzy\n'
        'msgid ""\n'
        'msgstr ""\n'
        '"Project-Id-Version: dtMediaWiki\\n"\n'
        '"Report-Msgid-Bugs-To: \\n"\n'
        '"POT-Creation-Date: %s\\n"\n'
        '"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\\n"\n'
        '"Last-Translator: AUTOGENERATED\\n"\n'
        '"Language-Team: \\n"\n'
        '"Language: en\\n"\n'
        '"MIME-Version: 1.0\\n"\n'
        '"Content-Type: text/plain; charset=UTF-8\\n"\n'
        '"Content-Transfer-Encoding: 8bit\\n"'
    ) % date


def generate_pot(entries, date):
    blocks = [_pot_header(date)]
    for msgid, locations in entries:
        blocks.append(_entry(msgid, locations, ""))
    return "\n\n".join(blocks) + "\n"


# ---------------------------------------------------------------------------
# .po parsing and merging
# ---------------------------------------------------------------------------

def _read_po_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()


def _parse_po(path):
    """Return {msgid: msgstr} for a .po file, skipping the header entry."""
    lines = _read_po_lines(path)
    translations = {}
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i].rstrip("\n")
        if line.startswith("msgid "):
            msgid_parts = [line[len("msgid "):]]
            i += 1
            while i < n and lines[i].startswith('"'):
                msgid_parts.append(lines[i].rstrip("\n"))
                i += 1
            msgid = _decode(msgid_parts)
            msgstr = ""
            if i < n and lines[i].startswith("msgstr "):
                msgstr_parts = [lines[i][len("msgstr "):].rstrip("\n")]
                i += 1
                while i < n and lines[i].startswith('"'):
                    msgstr_parts.append(lines[i].rstrip("\n"))
                    i += 1
                msgstr = _decode(msgstr_parts)
            if msgid != "":
                translations[msgid] = msgstr
            continue
        i += 1
    return translations


def _header_lines(lines):
    """Return the raw lines of the leading header entry (msgid "" block)."""
    out = []
    i = 0
    n = len(lines)
    while i < n and not lines[i].startswith('msgid ""'):
        out.append(lines[i].rstrip("\n"))
        i += 1
    out.append(lines[i].rstrip("\n"))
    i += 1
    while i < n and lines[i].startswith('"'):
        out.append(lines[i].rstrip("\n"))
        i += 1
    if i < n and lines[i].startswith("msgstr "):
        out.append(lines[i].rstrip("\n"))
        i += 1
        while i < n and lines[i].startswith('"'):
            out.append(lines[i].rstrip("\n"))
            i += 1
    return out


def _decode(parts):
    """Join quoted .po segments and unescape them into a string."""
    raw = "".join(parts)
    segments = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
    value = "".join(segments)

    def repl(match):
        ch = match.group(1)
        return {"n": "\n", "t": "\t", "r": "\r"}.get(ch, ch)

    return re.sub(r"\\(.)", repl, value)


def _update_header(header_lines, date):
    """Return header lines with the POT-Creation-Date replaced by `date`."""
    out = []
    for line in header_lines:
        if line.startswith('"POT-Creation-Date:'):
            out.append('"POT-Creation-Date: %s\\n"' % date)
        else:
            out.append(line)
    return out


def merge_po(entries, po_path, date):
    """Generate the merged .po content for the given entries."""
    lines = _read_po_lines(po_path)
    translations = _parse_po(po_path)
    header_lines = _update_header(_header_lines(lines), date)

    blocks = ["\n".join(header_lines)]
    for msgid, locations in entries:
        blocks.append(_entry(msgid, locations, translations.get(msgid, "")))
    return "\n\n".join(blocks) + "\n"


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

def compile_mo(po_path, mo_path):
    subprocess.run(
        ["msgfmt", "--check-format", "-o", mo_path, po_path],
        check=True,
    )


def po_files():
    pattern = os.path.join(LOCALE_DIR, "*", "LC_MESSAGES", DOMAIN + ".po")
    return sorted(glob.glob(pattern))


# ---------------------------------------------------------------------------
# Update and check
# ---------------------------------------------------------------------------

def entries_equal(a, b):
    if len(a) != len(b):
        return False
    for (m1, l1), (m2, l2) in zip(a, b):
        if m1 != m2 or sorted(l1) != sorted(l2):
            return False
    return True


def read_pot_entries(path):
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    entries = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i].rstrip("\n")
        if line.startswith("msgid "):
            msgid_start = i
            msgid_parts = [line[len("msgid "):]]
            i += 1
            while i < n and lines[i].startswith('"'):
                msgid_parts.append(lines[i].rstrip("\n"))
                i += 1
            msgid = _decode(msgid_parts)
            if msgid != "":
                # gather the #: locations that immediately precede this entry
                locs = []
                k = msgid_start - 1
                while k >= 0 and (
                    lines[k].startswith("#:") or lines[k].strip() == ""
                ):
                    if lines[k].startswith("#:"):
                        locs.append(lines[k].rstrip("\n")[2:].strip())
                    k -= 1
                entries.append((msgid, list(reversed(locs))))
            continue
        i += 1
    return entries


def run():
    entries = collect_entries()

    # Keep the existing creation date when the strings did not change, so a
    # no-op run does not produce a spurious diff.
    date = _now()
    if os.path.exists(POT_PATH):
        old_entries = read_pot_entries(POT_PATH)
        old_date = None
        with open(POT_PATH, encoding="utf-8") as f:
            for line in f:
                m = re.match(r'"POT-Creation-Date: (.*)\\n"', line)
                if m:
                    old_date = m.group(1)
                    break
        if old_date and entries_equal(entries, old_entries):
            date = old_date

    with open(POT_PATH, "w", encoding="utf-8") as f:
        f.write(generate_pot(entries, date))
    print("wrote %s (%d strings)" % (os.path.relpath(POT_PATH, ROOT),
                                     len(entries)))

    for po in po_files():
        content = merge_po(entries, po, date)
        with open(po, "w", encoding="utf-8") as f:
            f.write(content)
        mo = po[:-3] + ".mo"
        compile_mo(po, mo)
        translations = _parse_po(po)
        translated = sum(
            1 for mid, _ in entries
            if translations.get(mid, "") != ""
        )
        print("updated %s (%d translated)" % (os.path.relpath(po, ROOT),
                                              translated))


def check():
    code_ids = {mid for mid, _ in collect_entries()}

    if not os.path.exists(POT_PATH):
        print("error: %s is missing" % os.path.relpath(POT_PATH, ROOT))
        return 1

    pot_ids = {mid for mid, _ in read_pot_entries(POT_PATH)}
    missing = code_ids - pot_ids
    stale = pot_ids - code_ids
    if missing or stale:
        print("error: %s is out of sync with the source" %
              os.path.relpath(POT_PATH, ROOT))
        for s in sorted(missing):
            print("  missing: %r" % s)
        for s in sorted(stale):
            print("  stale:   %r" % s)
        print("run: tools/update-translations.py")
        return 1

    for po in po_files():
        translations = _parse_po(po)
        po_ids = set(translations.keys())
        missing = code_ids - po_ids
        stale = po_ids - code_ids
        if missing or stale:
            print("error: %s is out of sync with the source" %
                  os.path.relpath(po, ROOT))
            for s in sorted(missing):
                print("  missing: %r" % s)
            for s in sorted(stale):
                print("  stale:   %r" % s)
            print("run: tools/update-translations.py")
            return 1

    print("translation catalogs are in sync (%d strings)" % len(code_ids))
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Regenerate dtMediaWiki translation catalogs."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the catalogs match the source; exit 1 if not",
    )
    args = parser.parse_args()

    if args.check:
        sys.exit(check())
    run()


if __name__ == "__main__":
    main()
