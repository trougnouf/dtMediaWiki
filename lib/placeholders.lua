--[[
  dtMediaWiki placeholder engine
  -- dtMediaWiki metadata and placeholder definitions

  Goals:
    * central registry for all placeholders
    * placeholders can be added without changing the expansion engine
    * individual placeholders can be disabled
    * custom placeholders can override built-in placeholders
    * image-specific Commons metadata stored as darktable tags
    * no dependency on the MediaWiki transport layer
]]

local dt = require "darktable"

local i18n =
  require "contrib/dtMediaWiki/lib/i18n"

local _ =
  i18n.translate

local M = {}

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------

M.config = {
  -- Placeholder syntax:
  --   <title>
  --   <description_de>
  -- etc.

  unknown_placeholder = "keep", -- "keep" or "empty"

  -- Individual placeholders may be disabled here.
  disabled = {
    -- cameraMake = true,
    -- cameraModel = true,
    -- latitude = true,
    -- longitude = true,
  }
}

-----------------------------------------------------------------------
-- Registry
-----------------------------------------------------------------------

local registry = {}
local order = {}

local function register_internal(def)

  assert(type(def) == "table",
    "placeholder definition must be a table")

  assert(type(def.name) == "string",
    "placeholder requires a name")

  assert(type(def.get) == "function",
    "placeholder requires a get function")

  -- Only add to display order the first time.
  if registry[def.name] == nil then
    table.insert(order, def.name)
  end

  registry[def.name] = def
end

function M.register(def)
  register_internal(def)
end

function M.unregister(name)

  registry[name] = nil

  for i, value in ipairs(order) do
    if value == name then
      table.remove(order, i)
      break
    end
  end
end

function M.enable(name)
  M.config.disabled[name] = nil
end

function M.disable(name)
  M.config.disabled[name] = true
end

function M.is_enabled(name)

  return registry[name] ~= nil
     and not M.config.disabled[name]
end

function M.get_definition(name)
  return registry[name]
end

function M.list()

  local result = {}

  -- Not "for _, name": "_" would hide the translate function.
  for i = 1, #order do

    local name = order[i]
    local def = registry[name]

    if def then

      table.insert(result, {
        name        = name,
        label       = def.label or name,
        group       = def.group or _("Other"),
        description = def.description or "",
        enabled     = M.is_enabled(name)
      })

    end
  end

  return result
end

function M.list_enabled()

  local result = {}

  for _, def in ipairs(M.list()) do
    if def.enabled then
      table.insert(result, def)
    end
  end

  table.sort(
    result,
    function(a, b)
      if a.group == b.group then
        return a.name < b.name
      end
      return a.group < b.group
    end
  )

  return result
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function value_or_empty(value)

  if value == nil then
    return ""
  end

  return tostring(value)
end

local function trim(value)

  if not value then
    return ""
  end

  return value
    :gsub("^%s+", "")
    :gsub("%s+$", "")
end

-----------------------------------------------------------------------
-- Original filename helpers
-----------------------------------------------------------------------

local function original_filename(image)

  if not image or not image.filename then
    return ""
  end

  return tostring(image.filename)
end

local function basename(filename)

  -- Remove path, if one happens to be present.
  filename =
    filename:gsub("\\", "/")
            :match("([^/]+)$")
    or filename

  -- Remove final extension only.
  return filename:match("^(.*)%.([^.]*)$")
      or filename
end

local function extension(filename)

  filename =
    filename:gsub("\\", "/")
            :match("([^/]+)$")
    or filename

  return filename:match("%.([^.]*)$")
      or ""
end

-----------------------------------------------------------------------
-- Filename expansion
-----------------------------------------------------------------------

local function sanitize_filename_component(value)

  value = tostring(value or "")

  -- Characters forbidden/problematic in filenames, especially Windows.
  value = value:gsub('[<>:"/\\|?*]', "_")

  -- Whitespace becomes underscore.
  value = value:gsub("%s+", "_")

  -- Avoid repeated underscores.
  value = value:gsub("_+", "_")

  return value
end

function M.expand_filename(image, template, context)

  if template == nil then
    return ""
  end

  template = tostring(template)

  return template:gsub(
    "<([%w_]+)>",
    function(name)

      local value, err =
        M.resolve(
          image,
          name,
          context or {}
        )

      if err then

        if M.config.unknown_placeholder == "empty" then
          return ""
        end

        return "<" .. name .. ">"
      end

      return sanitize_filename_component(value)
    end
  )
end

-----------------------------------------------------------------------
-- Date parsing
--
-- darktable normally supplies:
--   YYYY:MM:DD HH:MM:SS
-----------------------------------------------------------------------

local function parse_datetime(value)

  if not value then
    return nil
  end

  local year, month, day,
        hour, minute, second =
    tostring(value):match(
      "^(%d%d%d%d):(%d%d):(%d%d)%s+(%d%d):(%d%d):(%d%d)"
    )

  if not year then
    return nil
  end

  return {
    year   = year,
    month  = month,
    day    = day,
    hour   = hour,
    minute = minute,
    second = second
  }
end

local function image_datetime(image)

  if not image then
    return nil
  end

  return parse_datetime(
    image.exif_datetime_taken
  )
end

function M.parse_categories(text)

  local categories = {}

  text = tostring(text or "")

  -- Semicolons and line breaks are equivalent separators.
  text = text:gsub("\r\n", ";")
  text = text:gsub("[\r\n]", ";")

  for entry in text:gmatch("[^;]+") do

    local item = trim(entry)

    -- Also accept complete Commons category syntax.
    item = item:gsub(
      "^%[%[[Cc]ategory:%s*",
      ""
    )

    item = item:gsub("%]%]$", "")
    item = trim(item)

    if item ~= "" then
      table.insert(categories, item)
    end
  end

  return categories
end

-----------------------------------------------------------------------
-- dtMediaWiki private metadata tags
-----------------------------------------------------------------------

local TAG_ROOT = "dtMediaWiki"

local function tag_prefix(field)

  return TAG_ROOT ..
         "|" ..
         field ..
         "|"
end

local function attached_tags(image)

  if not image then
    return {}
  end

  return dt.tags.get_tags(image)
      or {}
end

-----------------------------------------------------------------------
-- Single-value metadata
-----------------------------------------------------------------------

function M.get_metadata(image, field)

  local prefix =
    tag_prefix(field)

  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    if name:sub(1, #prefix) == prefix then

      return name:sub(
        #prefix + 1
      )

    end
  end

  return ""
end

function M.set_metadata(image, field, value)

  if not image then
    return false
  end

  local prefix =
    tag_prefix(field)

  -- Detach previous value(s).
  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    if name:sub(1, #prefix) == prefix then
      dt.tags.detach(tag, image)
    end
  end

  value = trim(value)

  if value == "" then
    return true
  end

  local tag =
    dt.tags.create(
      prefix .. value
    )

  dt.tags.attach(tag, image)

  return true
end

-----------------------------------------------------------------------
-- Multi-value metadata
-----------------------------------------------------------------------

function M.get_metadata_values(image, field)

  local result = {}

  local prefix =
    tag_prefix(field)

  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    if name:sub(1, #prefix) == prefix then

      table.insert(
        result,
        name:sub(#prefix + 1)
      )

    end
  end

  table.sort(result)

  return result
end

-----------------------------------------------------------------------
-- Internal metadata tag helper
-----------------------------------------------------------------------

local function create_private_tag(name)

  name = trim(name)

  if name == "" then
    return nil
  end

  -- Reuse an existing tag.
  local existing =
    dt.tags.find(name)

  if existing then
    return existing
  end

  -- Otherwise create it.
  return dt.tags.create(name)
end

function M.set_metadata_values(image, field, values)

  if not image then
    return false
  end

  local prefix =
    tag_prefix(field)

  -- Remove previous values.
  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    if name:sub(1, #prefix) == prefix then
      dt.tags.detach(tag, image)
    end
  end

  local seen = {}

  for _, value in ipairs(values or {}) do

    value = trim(value)

    if value ~= ""
        and not seen[value] then

      seen[value] = true

      local tag =
        create_private_tag(
          prefix .. value
        )

      if tag then
        dt.tags.attach(tag, image)
      end
    end
  end

  return true
end

-----------------------------------------------------------------------
-- Commons categories
-----------------------------------------------------------------------

-- Categories are stored in the library as tags, in two formats:
-- the legacy "Category:..." tags and the private
-- "dtMediaWiki|category|..." tags. Both are read back as plain
-- names and both are exported as "[[Category:...]]". The format
-- used when saving from the metadata panel is a user preference.
M.CATEGORY_PREFIX = "Category:"
M.CATEGORY_TAG_PREFIX = tag_prefix("category")

local function category_tag_prefix()

  local pref =
    dt.preferences.read(
      "mediawiki",
      "category_tag",
      "enum"
    )

  if pref == M.CATEGORY_TAG_PREFIX then
    return M.CATEGORY_TAG_PREFIX
  end

  return M.CATEGORY_PREFIX
end

function M.get_categories(image)

  local result = {}
  local seen = {}

  local prefixes = {
    M.CATEGORY_PREFIX,
    M.CATEGORY_TAG_PREFIX
  }

  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    for _, prefix in ipairs(prefixes) do

      if name:sub(1, #prefix) == prefix then

        local value =
          name:sub(#prefix + 1)

        if value ~= "" and not seen[value] then
          seen[value] = true
          table.insert(result, value)
        end

        break
      end
    end
  end

  table.sort(result)

  return result
end

function M.set_categories(image, categories)

  if not image then
    return false
  end

  local prefix =
    category_tag_prefix()

  local prefixes = {
    M.CATEGORY_PREFIX,
    M.CATEGORY_TAG_PREFIX
  }

  -- Detach previous values, in either format.
  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    for _, p in ipairs(prefixes) do

      if name:sub(1, #p) == p then
        dt.tags.detach(tag, image)
        break
      end
    end
  end

  local seen = {}

  for _, value in ipairs(categories or {}) do

    value = trim(value)

    if value ~= "" and not seen[value] then

      seen[value] = true

      local tag =
        create_private_tag(
          prefix .. value
        )

      if tag then
        dt.tags.attach(tag, image)
      end
    end
  end

  return true
end

-----------------------------------------------------------------------
-- Commons descriptions
-----------------------------------------------------------------------

-- Descriptions are stored as "dtMediaWiki|description_<lang>|text"
-- tags. Only two- or three-letter language codes are matched, so
-- the free-form "description_other" field is not included here.
function M.get_descriptions(image)

  local result = {}

  for _, tag in ipairs(attached_tags(image)) do

    local name =
      tostring(tag.name or "")

    local lang =
      name:match(
        "^dtMediaWiki|description_([%a][%a][%a]?)|"
      )

    if lang then

      local prefix =
        "dtMediaWiki|description_"
        .. lang
        .. "|"

      table.insert(
        result,
        {
          lang = lang,
          text = name:sub(#prefix + 1)
        }
      )
    end
  end

  table.sort(
    result,
    function(a, b)
      return a.lang < b.lang
    end
  )

  return result
end

-----------------------------------------------------------------------
-- Placeholder lookup
-----------------------------------------------------------------------

function M.resolve(image, name, context)

  local def =
    registry[name]

  if not def then
    return nil, "unknown"
  end

  if M.config.disabled[name] then
    return nil, "disabled"
  end

  local ok, result =
    pcall(
      def.get,
      image,
      context or {}
    )

  if not ok then

    dt.print_error(
      "dtMediaWiki placeholder <" ..
      name ..
      "> failed: " ..
      tostring(result)
    )

    return "", "error"
  end

  return value_or_empty(result), nil
end

-----------------------------------------------------------------------
-- Template expansion
-----------------------------------------------------------------------

function M.expand(image, template, context)

  if template == nil then
    return ""
  end

  template =
    tostring(template)

  return template:gsub(
    "<([%w_]+)>",
    function(name)

      local value, err =
        M.resolve(
          image,
          name,
          context
        )

      if not err then
        return value
      end

      if M.config.unknown_placeholder
          == "empty" then

        return ""
      end

      -- Keep unknown/disabled placeholders visible.
      -- This is especially useful in the preview.
      return "<" .. name .. ">"
    end
  )
end

-----------------------------------------------------------------------
-- Built-in placeholder definitions
-----------------------------------------------------------------------

register_internal {
  name  = "fileName",
  label = _("File name"),
  group = _("File"),

  description =
    "Original base name with the export file extension",

  get = function(image, context)

    local source =
      original_filename(image)

    local base =
      basename(source)

    local ext =
      context.export_extension
      or extension(source)

    if ext ~= "" then
      return base .. "." .. ext
    end

    return base
  end
}

register_internal {
  name  = "fileBaseName",
  label = _("File base name"),
  group = _("File"),

  get = function(image)
    return basename(
      original_filename(image)
    )
  end
}

register_internal {
  name  = "extension",
  label = _("Export extension"),
  group = _("File"),

  get = function(image, context)

    return context.export_extension
        or extension(
             original_filename(image)
           )
  end
}

-----------------------------------------------------------------------
-- Descriptive metadata
-----------------------------------------------------------------------

register_internal {
  name  = "title",
  label = _("Title"),
  group = _("Description"),

  get = function(image)
    return image and image.title or ""
  end
}

register_internal {
  name  = "description",
  label = _("darktable description"),
  group = _("Description"),

  get = function(image)
    return image
       and image.description
       or ""
  end
}

register_internal {
  name  = "description_de",
  label = _("German description"),
  group = _("Commons"),

  get = function(image)

    return M.get_metadata(
      image,
      "description_de"
    )
  end
}

register_internal {
  name  = "description_en",
  label = _("English description"),
  group = _("Commons"),

  get = function(image)

    return M.get_metadata(
      image,
      "description_en"
    )
  end
}

register_internal {
  name  = "creator",
  label = _("Creator"),
  group = _("Description"),

  get = function(image)
    return image and image.creator or ""
  end
}

register_internal {
  name  = "copyright",
  label = _("Copyright / rights"),
  group = _("Description"),

  get = function(image)
    return image and image.rights or ""
  end
}

-----------------------------------------------------------------------
-- Date
-----------------------------------------------------------------------

register_internal {
  name  = "dateTimeOriginal",
  label = _("Capture date/time"),
  group = _("Date"),

  get = function(image)

    return image
       and image.exif_datetime_taken
       or ""
  end
}

register_internal {
  name  = "dateYYYYMMDD",
  label = _("Date YYYYMMDD"),
  group = _("Date"),

  get = function(image)

    local d =
      image_datetime(image)

    if not d then
      return ""
    end

    return d.year ..
           d.month ..
           d.day
  end
}

register_internal {
  name  = "year",
  label = _("Year"),
  group = _("Date"),

  get = function(image)

    local d =
      image_datetime(image)

    return d and d.year or ""
  end
}

register_internal {
  name  = "month",
  label = _("Month"),
  group = _("Date"),

  get = function(image)

    local d =
      image_datetime(image)

    return d and d.month or ""
  end
}

register_internal {
  name  = "day",
  label = _("Day"),
  group = _("Date"),

  get = function(image)

    local d =
      image_datetime(image)

    return d and d.day or ""
  end
}

-----------------------------------------------------------------------
-- Camera / EXIF
-----------------------------------------------------------------------

register_internal {
  name  = "cameraMake",
  label = _("Camera manufacturer"),
  group = _("Camera"),

  get = function(image)
    return image and image.exif_maker or ""
  end
}

register_internal {
  name  = "cameraModel",
  label = _("Camera model"),
  group = _("Camera"),

  get = function(image)
    return image and image.exif_model or ""
  end
}

register_internal {
  name  = "lens",
  label = _("Lens"),
  group = _("Camera"),

  get = function(image)
    return image and image.exif_lens or ""
  end
}

register_internal {
  name  = "focalLength",
  label = _("Focal length"),
  group = _("Camera"),

  get = function(image)

    if not image
        or not image.exif_focal_length then
      return ""
    end

    return tostring(
      image.exif_focal_length
    )
  end
}

register_internal {
  name  = "aperture",
  label = _("Aperture"),
  group = _("Camera"),

  get = function(image)

    if not image
        or not image.exif_aperture then
      return ""
    end

    return tostring(
      image.exif_aperture
    )
  end
}

register_internal {
  name  = "shutterSpeed",
  label = _("Exposure time"),
  group = _("Camera"),

  get = function(image)

    if not image
        or not image.exif_exposure then
      return ""
    end

    return tostring(
      image.exif_exposure
    )
  end
}

register_internal {
  name  = "iso",
  label = _("ISO"),
  group = _("Camera"),

  get = function(image)

    if not image
        or not image.exif_iso then
      return ""
    end

    return tostring(
      image.exif_iso
    )
  end
}

-----------------------------------------------------------------------
-- Location
-----------------------------------------------------------------------

register_internal {
  name  = "latitude",
  label = _("GPS latitude"),
  group = _("Location"),

  get = function(image)

    if not image
        or image.latitude == nil then
      return ""
    end

    return tostring(image.latitude)
  end
}

register_internal {
  name  = "longitude",
  label = _("GPS longitude"),
  group = _("Location"),

  get = function(image)

    if not image
        or image.longitude == nil then
      return ""
    end

    return tostring(image.longitude)
  end
}

register_internal {
  name  = "altitude",
  label = _("GPS altitude"),
  group = _("Location"),

  get = function(image)

    if not image
        or image.elevation == nil then
      return ""
    end

    return tostring(image.elevation)
  end
}

-----------------------------------------------------------------------
-- Commons metadata field registry
-----------------------------------------------------------------------

-- Language codes for which the Commons metadata panel shows a
-- description field, from the "description_langs" preference.
-- Two- or three-letter codes only; anything else is ignored.
local function description_langs()

  local pref =
    dt.preferences.read(
      "mediawiki",
      "description_langs",
      "string"
    )

  pref = tostring(pref or "")
      :gsub(";", ",")

  local langs = {}
  local seen = {}

  for code in pref:gmatch("[^,]+") do

    local lang = trim(code)

    if lang:match("^[%a][%a][%a]?$")
        and not seen[lang] then

      seen[lang] = true
      table.insert(langs, lang)
    end
  end

  if #langs == 0 then
    table.insert(langs, "en")
  end

  return langs
end

local metadata_fields = {}

-- Not "for _, lang": "_" would hide the translate function.
local langs = description_langs()

for i = 1, #langs do

  local lang =
    langs[i]

  table.insert(
    metadata_fields,
    {
      name = "description_" .. lang,
      storage_name = "description_" .. lang,
      label = string.format(
        _("Description (%s)"),
        lang
      ),
      group = _("Description"),
      multiple = false,
      preset = true,
      preset_apply = "if_empty",
      widget = "entry",
    }
  )
end

table.insert(
  metadata_fields,
  {
    name = "description_other",
    storage_name = "description_other",
    label = _("Other descriptions"),
    tooltip = _("Values are separated by semicolons."),
    group = _("Description"),
    multiple = true,
    preset = true,
    preset_apply = "if_empty",
    widget = "entry",
  }
)

table.insert(
  metadata_fields,
  {
    name = "templates",
    storage_name = "template",
    label = _("Templates"),
    tooltip = _("Values are separated by semicolons."),
    group = _("Commons"),
    multiple = true,
    preset = true,
    preset_apply = "add",
    widget = "entry",
  }
)

table.insert(
  metadata_fields,
  {
    name = "categories",
    storage_name = "category",
    label = _("Categories"),
    tooltip =
      _("Commons categories as plain names, separated by semicolons. "
        .. "Existing Category: and dtMediaWiki|category| tags are "
        .. "shown and managed here as plain names."),
    group = _("Commons"),
    multiple = true,
    preset = true,
    preset_apply = "add",
    parser = "categories",
    widget = "entry",
  }
)

table.insert(
  metadata_fields,
  {
    name = "wikidata",
    storage_name = "wikidata",
    label = _("Wikidata"),
    tooltip = _("Values are separated by semicolons."),
    group = _("Commons"),
    multiple = true,
    preset = true,
    preset_apply = "add",
    widget = "entry",
  }
)

table.insert(
  metadata_fields,
  {
    name = "other_versions",
    storage_name = "other_version",
    label = _("Other versions"),
    tooltip = _("Values are separated by semicolons."),
    group = _("Commons"),
    multiple = true,
    preset = true,
    preset_apply = "add",
    widget = "entry",
  }
)

table.insert(
  metadata_fields,
  {
    name = "other_fields",
    storage_name = "other_field",
    label = _("Other fields"),
    tooltip = _("Values are separated by semicolons."),
    group = _("Commons"),
    multiple = true,
    preset = true,
    preset_apply = "add",
    widget = "entry",
  }
)

local metadata_field_index = {}

for _, field in ipairs(metadata_fields) do
  metadata_field_index[field.name] = field
end

function M.list_metadata_fields()

  return metadata_fields
end


function M.get_metadata_field(name)

  local field =
    metadata_field_index[name]

  -- Descriptions for languages that are not in the
  -- "description_langs" preference are not shown in the panel,
  -- but are still readable and writable.
  if not field
      and name:match("^description_[%a][%a][%a]?$") then

    field = {
      name         = name,
      storage_name = name,
      label        = string.format(
        _("Description (%s)"),
        name:match("^description_([%a][%a][%a]?)$")
      ),
      group        = _("Description"),
      multiple     = false,
      widget       = "entry",
    }
  end

  return field
end

function M.get_field(image, name)

  local field =
    M.get_metadata_field(name)

  if not field then
    return nil, "unknown metadata field"
  end

  -- Categories are read from both the legacy "Category:" tags and
  -- the private "dtMediaWiki|category|" tags, and returned as
  -- plain names.
  if name == "categories" then
    return M.get_categories(image)
  end

  if field.multiple then

    return M.get_metadata_values(
      image,
      field.storage_name
    )

  end

  return M.get_metadata(
    image,
    field.storage_name
  )
end


function M.set_field(image, name, value)

  local field =
    M.get_metadata_field(name)

  if not field then
    return false, "unknown metadata field"
  end

  -- Categories are written using the user's preferred tag format;
  -- any existing category tags (in either format) are replaced.
  if name == "categories" then
    return M.set_categories(image, value or {})
  end

  if field.multiple then

    return M.set_metadata_values(
      image,
      field.storage_name,
      value or {}
    )

  end

  return M.set_metadata(
    image,
    field.storage_name,
    value or ""
  )
end

-----------------------------------------------------------------------
-- Public registry access
-----------------------------------------------------------------------

M.registry = registry

return M
