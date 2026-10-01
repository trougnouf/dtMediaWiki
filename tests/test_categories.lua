--[[
  Functional tests for the dtMediaWiki placeholder engine:
  Commons categories (both tag formats), per-language descriptions,
  and the Commons metadata field registry.

  Runs standalone: lua tests/test_categories.lua
  No darktable installation required; the darktable API is stubbed.
]]

-----------------------------------------------------------------------
-- Locate the repository root (this file lives in tests/)
-----------------------------------------------------------------------

local source =
  debug.getinfo(1, "S").source:gsub("^@", "")

local root =
  source:match("^(.+)/tests/") or "."

-----------------------------------------------------------------------
-- Minimal test framework
-----------------------------------------------------------------------

local passed = 0
local failed = 0

local function check(name, ok, detail)

  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name
      .. (detail and (": " .. detail) or ""))
  end
end

local function same_table(a, b)

  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end

  if #a ~= #b then
    return false
  end

  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end

  return true
end

local function field_names(fields)

  local names = {}

  for _, field in ipairs(fields) do
    table.insert(names, field.name)
  end

  return names
end

local function contains(list, value)

  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end

  return false
end

local function index_of(list, value)

  for i, item in ipairs(list) do
    if item == value then
      return i
    end
  end

  return nil
end

local function tag_names(image)

  local names = {}

  for _, tag in ipairs(image.tags) do
    table.insert(names, tag.name)
  end

  table.sort(names)

  return names
end

-----------------------------------------------------------------------
-- darktable API stub
-----------------------------------------------------------------------

local tag_db = {}

local dt_stub = {}

dt_stub.configuration = { config_dir = "/tmp" }

dt_stub.print = function() end
dt_stub.print_log = function() end
dt_stub.print_error = function() end

dt_stub.gettext = {
  bindtextdomain = function() end,
  dgettext = function(_, msgid)
    return msgid
  end
}

local prefs = {}

dt_stub.preferences = {
  read = function(prefix, name, _)
    return prefs[prefix .. "/" .. name]
  end,
  write = function(prefix, name, _, value)
    prefs[prefix .. "/" .. name] = value
  end
}

dt_stub.tags = {
  -- darktable returns a fresh list on each call, so the caller
  -- may detach tags while iterating it.
  get_tags = function(image)
    local result = {}
    for _, tag in ipairs(image and image.tags or {}) do
      table.insert(result, tag)
    end
    return result
  end,
  attach = function(tag, image)
    for _, t in ipairs(image.tags) do
      if t == tag then
        return
      end
    end
    table.insert(image.tags, tag)
  end,
  detach = function(tag, image)
    for i = #image.tags, 1, -1 do
      if image.tags[i] == tag then
        table.remove(image.tags, i)
      end
    end
  end,
  create = function(name)
    tag_db[name] = tag_db[name] or { name = name }
    return tag_db[name]
  end,
  find = function(name)
    return tag_db[name]
  end
}

package.loaded["darktable"] = dt_stub

package.preload["contrib/dtMediaWiki/lib/i18n"] = function()
  return dofile(root .. "/lib/i18n.lua")
end

local function load_placeholders()

  package.loaded["contrib/dtMediaWiki/lib/placeholders"] = nil

  return dofile(root .. "/lib/placeholders.lua")
end

local function make_image(filename)

  return {
    filename = filename or "IMG_0001.jpg",
    title = "",
    description = "",
    tags = {}
  }
end

-- Register the tag in the stub's tag database, as darktable does,
-- so that dt.tags.find can locate it.
local function attach(image, name)

  local tag =
    dt_stub.tags.create(name)

  dt_stub.tags.attach(tag, image)
end

-----------------------------------------------------------------------
-- parse_categories
-----------------------------------------------------------------------

local P = load_placeholders()

check("parse_categories: semicolon separated",
  same_table(P.parse_categories("A; B"), { "A", "B" }))

check("parse_categories: newline separated",
  same_table(P.parse_categories("A\nB"), { "A", "B" }))

check("parse_categories: CRLF separated",
  same_table(P.parse_categories("A\r\nB"), { "A", "B" }))

check("parse_categories: mixed separators",
  same_table(P.parse_categories("A; B\nC\r\nD"),
    { "A", "B", "C", "D" }))

check("parse_categories: trims and drops empties",
  same_table(P.parse_categories("  A ;  ; B\n\n"),
    { "A", "B" }))

check("parse_categories: empty input",
  same_table(P.parse_categories(""), {}))

-----------------------------------------------------------------------
-- Categories: reading
-----------------------------------------------------------------------

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:PowerShed" })
  table.insert(img.tags,
    { name = "dtMediaWiki|category|Glass doors" })
  table.insert(img.tags, { name = "Category:Glass doors" })
  table.insert(img.tags, { name = "unrelated tag" })

  check("get_categories: both formats, deduped, sorted",
    same_table(P.get_categories(img),
      { "Glass doors", "PowerShed" }))
end

do
  local img = make_image()
  check("get_categories: no tags",
    same_table(P.get_categories(img), {}))
end

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:" })
  table.insert(img.tags, { name = "dtMediaWiki|category|" })
  check("get_categories: empty category names ignored",
    same_table(P.get_categories(img), {}))
end

-----------------------------------------------------------------------
-- Categories: writing
-----------------------------------------------------------------------

do
  prefs["mediawiki/category_tag"] = nil
  local img = make_image()
  P.set_categories(img, { "B", "A" })

  check("set_categories: default writes Category: tags",
    same_table(tag_names(img),
      { "Category:A", "Category:B" }))
end

do
  prefs["mediawiki/category_tag"] = "dtMediaWiki|category|"
  local img = make_image()
  P.set_categories(img, { "B", "A" })

  check("set_categories: private tag format from preference",
    same_table(tag_names(img),
      { "dtMediaWiki|category|A", "dtMediaWiki|category|B" }))
end

do
  prefs["mediawiki/category_tag"] = "dtMediaWiki|category|"
  local img = make_image()
  table.insert(img.tags, { name = "Category:Old" })
  table.insert(img.tags, { name = "dtMediaWiki|category|Older" })
  P.set_categories(img, { "New" })

  check("set_categories: replaces both existing formats",
    same_table(P.get_categories(img), { "New" }))
end

do
  prefs["mediawiki/category_tag"] = nil
  local img = make_image()
  P.set_categories(img, { "A", " A ", "B", "" })

  check("set_categories: trims, drops empties, dedupes",
    same_table(P.get_categories(img), { "A", "B" }))
end

do
  local img = make_image()
  P.set_field(img, "categories", { "Y", "X" })

  check("set_field/get_field: categories",
    same_table(P.get_field(img, "categories"),
      { "X", "Y" }))
end

-----------------------------------------------------------------------
-- Categories: incremental operations
-----------------------------------------------------------------------

do
  prefs["mediawiki/category_tag"] = nil
  local img = make_image()
  table.insert(img.tags, { name = "unrelated" })

  P.add_category(img, "Foo")

  check("add_category: default writes Category: tag",
    same_table(tag_names(img),
      { "Category:Foo", "unrelated" }))
end

do
  prefs["mediawiki/category_tag"] = "dtMediaWiki|category|"
  local img = make_image()

  P.add_category(img, "Foo")

  check("add_category: private tag format from preference",
    same_table(tag_names(img),
      { "dtMediaWiki|category|Foo" }))
end

do
  prefs["mediawiki/category_tag"] = "dtMediaWiki|category|"
  local img = make_image()
  attach(img, "Category:Foo")

  P.add_category(img, "Foo")

  check("add_category: normalizes duplicate in other format",
    same_table(tag_names(img),
      { "dtMediaWiki|category|Foo" }))
end

do
  prefs["mediawiki/category_tag"] = nil
  local img = make_image()
  attach(img, "dtMediaWiki|category|Foo")

  P.add_category(img, "Foo")

  check("add_category: normalizes private duplicate to default",
    same_table(tag_names(img), { "Category:Foo" }))
end

do
  prefs["mediawiki/category_tag"] = nil
  local img = make_image()
  attach(img, "Category:Foo")

  local ok = P.add_category(img, "  Foo  ")

  check("add_category: trims, idempotent, returns true",
    ok and same_table(tag_names(img), { "Category:Foo" }))
end

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:Foo" })

  check("add_category: empty name is a no-op",
    P.add_category(img, "  ") == false
    and same_table(tag_names(img), { "Category:Foo" }))

  check("add_category: nil image is a no-op",
    P.add_category(nil, "Foo") == false)
end

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:Foo" })

  check("remove_category: detaches legacy tag",
    P.remove_category(img, "Foo")
    and same_table(tag_names(img), {}))
end

do
  local img = make_image()
  table.insert(img.tags,
    { name = "dtMediaWiki|category|Foo" })

  check("remove_category: detaches private tag",
    P.remove_category(img, "Foo")
    and same_table(tag_names(img), {}))
end

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:Foo" })
  table.insert(img.tags,
    { name = "dtMediaWiki|category|Foo" })
  table.insert(img.tags, { name = "Category:Bar" })

  P.remove_category(img, "Foo")

  check("remove_category: detaches both formats, keeps others",
    same_table(tag_names(img), { "Category:Bar" }))
end

do
  local img = make_image()
  table.insert(img.tags, { name = "Category:Foo" })

  check("remove_category: absent category returns false",
    P.remove_category(img, "Bar") == false
    and same_table(tag_names(img), { "Category:Foo" }))

  check("remove_category: empty name is a no-op",
    P.remove_category(img, "") == false)

  check("remove_category: nil image is a no-op",
    P.remove_category(nil, "Foo") == false)
end

-----------------------------------------------------------------------
-- Metadata fields
-----------------------------------------------------------------------

do
  local names = field_names(P.list_metadata_fields())

  check("fields: description_en present by default",
    contains(names, "description_en"))

  check("fields: description_de absent by default",
    not contains(names, "description_de"))

  check("fields: description_other present",
    contains(names, "description_other"))

  check("fields: categories present",
    contains(names, "categories"))

  check("fields: templates present",
    contains(names, "templates"))
end

do
  prefs["mediawiki/description_langs"] = "en,de"
  local P2 = load_placeholders()
  local names = field_names(P2.list_metadata_fields())

  check("fields: pref 'en,de' shows both",
    contains(names, "description_en")
    and contains(names, "description_de"))

  check("fields: pref order preserved",
    (index_of(names, "description_en")
      or 0) < (index_of(names, "description_de") or 0))
end

do
  prefs["mediawiki/description_langs"] = "fr;nl;xx-yy"
  local P3 = load_placeholders()
  local names = field_names(P3.list_metadata_fields())

  check("fields: only 2-3 letter codes kept",
    contains(names, "description_fr")
    and contains(names, "description_nl")
    and not contains(names, "description_xx-yy"))
end

do
  prefs["mediawiki/description_langs"] = ""
  local P4 = load_placeholders()
  local names = field_names(P4.list_metadata_fields())

  check("fields: empty pref falls back to 'en'",
    contains(names, "description_en")
    and not contains(names, "description_de"))
end

do
  prefs["mediawiki/description_langs"] = "en, en,de"
  local P5 = load_placeholders()
  local names = field_names(P5.list_metadata_fields())

  local count = 0

  for _, name in ipairs(names) do
    if name == "description_en" then
      count = count + 1
    end
  end

  check("fields: duplicate languages deduped",
    count == 1 and contains(names, "description_de"))
end

-----------------------------------------------------------------------
-- Descriptions: reading
-----------------------------------------------------------------------

do
  local img = make_image()
  table.insert(img.tags,
    { name = "dtMediaWiki|description_en|Hello" })
  table.insert(img.tags,
    { name = "dtMediaWiki|description_de|Hallo" })
  table.insert(img.tags,
    { name = "dtMediaWiki|description_other|{{fr|1=Bonjour}}" })

  local result = P.get_descriptions(img)

  check("get_descriptions: count (other excluded)",
    #result == 2)

  check("get_descriptions: sorted by language",
    #result == 2
    and result[1].lang == "de"
    and result[1].text == "Hallo"
    and result[2].lang == "en"
    and result[2].text == "Hello")
end

do
  local img = make_image()
  table.insert(img.tags,
    { name = "dtMediaWiki|description_en_us|Nope" })
  table.insert(img.tags,
    { name = "dtMediaWiki|description_english|Nope" })

  check("get_descriptions: 2-3 letter codes only",
    #P.get_descriptions(img) == 0)
end

do
  local img = make_image()
  check("get_descriptions: none",
    #P.get_descriptions(img) == 0)
end

-----------------------------------------------------------------------
-- Descriptions: reading/writing via fields
-----------------------------------------------------------------------

do
  local img = make_image()
  P.set_field(img, "description_en", "Hello")

  check("get_field: description_en",
    P.get_field(img, "description_en") == "Hello")

  P.set_field(img, "description_en", "")

  check("set_field: description_en cleared",
    P.get_field(img, "description_en") == "")
end

do
  -- "fr" is not in the default field list, but must still be
  -- readable and writable.
  local img = make_image()
  P.set_field(img, "description_fr", "Bonjour")

  check("get_field: hidden language readable",
    P.get_field(img, "description_fr") == "Bonjour")

  local result = P.get_descriptions(img)

  check("get_descriptions: hidden language included",
    #result == 1
    and result[1].lang == "fr"
    and result[1].text == "Bonjour")
end

do
  local img = make_image()
  P.set_field(img, "description_other",
    { "{{fr|1=Bonjour}}", "{{es|1=Hola}}" })

  check("set_field: description_other multiple",
    same_table(P.get_field(img, "description_other"),
      { "{{es|1=Hola}}", "{{fr|1=Bonjour}}" }))
end

do
  local img = make_image()
  P.set_metadata(img, "description_en", "  Trimmed  ")

  check("set_metadata: trims value",
    P.get_metadata(img, "description_en") == "Trimmed")
end

do
  local img = make_image()
  local value, err = P.get_field(img, "no_such_field")

  check("get_field: unknown field errors",
    value == nil and err ~= nil)
end

-----------------------------------------------------------------------
-- Placeholder expansion (sanity)
-----------------------------------------------------------------------

do
  local img = make_image("IMG_20240102_001.jpg")
  img.title = "My title"
  img.exif_datetime_taken = "2024:01:02 10:30:00"

  check("expand: title placeholder",
    P.expand(img, "<title>") == "My title")

  check("expand: year placeholder",
    P.expand(img, "<year>") == "2024")

  check("expand: unknown placeholder kept",
    P.expand(img, "<nope>") == "<nope>")

  check("expand_filename: sanitizes value",
    P.expand_filename(img, "<title>.jpg",
      { export_extension = "jpg" }) == "My_title.jpg")
end

-----------------------------------------------------------------------
-- Summary
-----------------------------------------------------------------------

print(string.format("%d passed, %d failed", passed, failed))

if failed > 0 then
  os.exit(1)
end
