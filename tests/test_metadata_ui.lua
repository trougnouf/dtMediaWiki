--[[
  Regression tests for the Commons metadata panel
  (lib/metadata_ui.lua).

  Categories: the panel shows a read-only view of the categories of
  the selected image(s) and changes them through incremental
  add/remove operations only. It never rewrites the whole category
  set, so categories attached elsewhere (native tag editor,
  category search) can never be dropped by the panel (issue #46).

  Other fields: a field is written back to the library only when its
  widget text differs from the value it was populated with on
  refresh (baseline guard); an unedited widget may be stale (e.g.
  after the title was changed in the native metadata editor) and
  writing it back would silently replace the library values.

  Runs standalone: lua tests/test_metadata_ui.lua
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

local function tag_names(image)

  local names = {}

  for _, tag in ipairs(image.tags) do
    table.insert(names, tag.name)
  end

  table.sort(names)

  return table.concat(names, ", ")
end

local function has_tag(image, name)

  for _, tag in ipairs(image.tags) do
    if tag.name == name then
      return true
    end
  end

  return false
end

-----------------------------------------------------------------------
-- Widget stub
--
-- dt.new_widget("type") { ... } is a nested call in Lua: the table
-- constructor is passed to the returned widget via __call, not to
-- new_widget itself.
-----------------------------------------------------------------------

local all_widgets = {}

local function make_widget(type_name)

  local w = setmetatable({}, {
    __call = function(self, spec)
      for k, v in pairs(spec or {}) do
        self[k] = v
      end
      self.children = spec
      return self
    end
  })

  w._type = type_name

  table.insert(all_widgets, w)

  return w
end

-- The last widget created with a tooltip starting with the given
-- prefix. The preset editor creates one widget per preset field
-- before the panel does, so the last match is the panel widget.
local function find_field_widget(tooltip_prefix)

  local found = nil

  for _, w in ipairs(all_widgets) do

    if type(w.tooltip) == "string"
        and w.tooltip:sub(1, #tooltip_prefix)
            == tooltip_prefix then

      found = w
    end
  end

  return found
end

-----------------------------------------------------------------------
-- darktable API stub
-----------------------------------------------------------------------

local tag_db = {}

local current_selection = {}
local event_handlers = {}
local prefs = {}

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

dt_stub.preferences = {
  read = function(prefix, name, _)
    return prefs[prefix .. "/" .. name]
  end,
  write = function(prefix, name, _, value)
    prefs[prefix .. "/" .. name] = value
  end
}

dt_stub.new_widget = function(type_name)
  return make_widget(type_name)
end

dt_stub.register_lib = function() end

dt_stub.register_event = function(_, signal, fn)
  event_handlers[signal] = event_handlers[signal] or {}
  table.insert(event_handlers[signal], fn)
end

dt_stub.gui = {
  selection = function()
    return current_selection
  end,
  views = { lighttable = "lighttable" }
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

package.preload["contrib/dtMediaWiki/lib/placeholders"] = function()
  return dofile(root .. "/lib/placeholders.lua")
end

package.preload["contrib/dtMediaWiki/lib/presets"] = function()
  return dofile(root .. "/lib/presets.lua")
end

package.preload["contrib/dtMediaWiki/lib/mediawikiapi"] = function()
  return dofile(root .. "/lib/mediawikiapi.lua")
end

package.preload["contrib/dtMediaWiki/lib/dkjson"] = function()
  return dofile(root .. "/lib/dkjson.lua")
end

-----------------------------------------------------------------------
-- Load the real metadata panel
-----------------------------------------------------------------------

local MetadataUI =
  dofile(root .. "/lib/metadata_ui.lua")

local function fire(signal)

  for _, fn in ipairs(event_handlers[signal] or {}) do
    fn()
  end
end

local function make_image(filename)

  return {
    filename = filename or "IMG_0001.jpg",
    title = "",
    description = "",
    tags = {}
  }
end

local function select(images)

  current_selection = images
  fire("selection-changed")
end

local function attach(image, name)

  dt_stub.tags.attach(
    dt_stub.tags.create(name),
    image
  )
end

local categories_view =
  find_field_widget("Current Commons categories")

local category_add_entry =
  find_field_widget("Category to add")

local category_add_button =
  find_field_widget("Add the entered category")

local category_remove_selector =
  find_field_widget("Select a category to remove")

local category_remove_button =
  find_field_widget("Remove the selected category")

local category_refresh_button =
  find_field_widget("Re-read the metadata")

local title_widget =
  find_field_widget("The darktable image title")

check("setup: categories view found",
  categories_view ~= nil)

check("setup: category add entry found",
  category_add_entry ~= nil)

check("setup: category add button found",
  category_add_button ~= nil)

check("setup: category remove selector found",
  category_remove_selector ~= nil)

check("setup: category remove button found",
  category_remove_button ~= nil)

check("setup: refresh button found",
  category_refresh_button ~= nil)

check("setup: title widget found",
  title_widget ~= nil)

-----------------------------------------------------------------------
-- Issue #46: tags changed outside the panel must survive
-----------------------------------------------------------------------

do
  -- Category added in the native tag editor, then the user changes
  -- selection (the panel saves the previous selection first).
  local A, B = make_image("A.jpg"), make_image("B.jpg")
  attach(A, "Category:Foo")

  select({ A })
  attach(A, "Category:Bar")
  select({ B })

  check("selection change keeps Category:Foo",
    has_tag(A, "Category:Foo"))

  check("selection change keeps natively added Category:Bar",
    has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Same, but the user starts the export instead of changing
  -- selection (register_storage_initialize calls MetadataUI.save()).
  local A = make_image("C.jpg")
  attach(A, "Category:Foo")

  select({ A })
  attach(A, "Category:Bar")
  MetadataUI.save()

  check("export save keeps natively added Category:Bar",
    has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Same, via the "Save metadata" button (save, then refresh).
  local A = make_image("D.jpg")
  attach(A, "Category:Foo")

  select({ A })
  attach(A, "Category:Bar")
  MetadataUI.save()
  MetadataUI.refresh()

  check("'Save metadata' keeps natively added Category:Bar",
    has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Control: a legacy {{...}} template tag added in the native tag
  -- editor was never managed by the panel and must survive.
  local A, B = make_image("E.jpg"), make_image("F.jpg")
  attach(A, "{{MyTemplate}}")

  select({ A })
  attach(A, "{{OtherTemplate}}")
  select({ B })

  check("selection change keeps legacy template tag",
    has_tag(A, "{{OtherTemplate}}"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Private template tags (dtMediaWiki|template|) are managed by
  -- the panel, so a stale write-back would have dropped them too.
  local A, B = make_image("G.jpg"), make_image("H.jpg")
  attach(A, "dtMediaWiki|template|T1")

  select({ A })
  attach(A, "dtMediaWiki|template|T2")
  select({ B })

  check("selection change keeps natively added private template",
    has_tag(A, "dtMediaWiki|template|T2"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Title set in the native metadata editor after the panel was
  -- populated (fixed earlier for title only, see 3fa21dc).
  local A, B = make_image("I.jpg"), make_image("J.jpg")
  A.title = "Original"

  select({ A })
  A.title = "Native"
  select({ B })

  check("selection change keeps natively set title",
    A.title == "Native",
    "A.title: " .. tostring(A.title))
end

-----------------------------------------------------------------------
-- Incremental category operations
-----------------------------------------------------------------------

do
  -- Add via the panel attaches the tags and updates the view.
  local A = make_image("K.jpg")

  select({ A })
  category_add_entry.text = "Foo; Bar"
  category_add_button.clicked_callback()

  check("add: attaches Category:Foo",
    has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")

  check("add: attaches Category:Bar",
    has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")

  check("add: clears the entry",
    category_add_entry.text == "")

  check("add: view shows the new categories",
    categories_view.text == "Bar; Foo",
    "view: " .. tostring(categories_view.text))
end

do
  -- The exact issue #46 scenario: a category attached in the
  -- native tag editor, then one added through the panel.
  local A = make_image("L.jpg")
  attach(A, "Category:Foo")

  select({ A })
  category_add_entry.text = "Bar"
  category_add_button.clicked_callback()

  check("panel add keeps natively attached Category:Foo",
    has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")

  check("panel add attaches Category:Bar",
    has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- [[Category:...]] syntax is accepted.
  local A = make_image("M.jpg")

  select({ A })
  category_add_entry.text = "[[Category:Glass doors]]"
  category_add_button.clicked_callback()

  check("add: accepts [[Category:...]] syntax",
    has_tag(A, "Category:Glass doors"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Adding a category that is already attached does not duplicate.
  local A = make_image("N.jpg")
  attach(A, "Category:Foo")

  select({ A })
  category_add_entry.text = "Foo"
  category_add_button.clicked_callback()

  local count = 0

  for _, tag in ipairs(A.tags) do
    if tag.name == "Category:Foo" then
      count = count + 1
    end
  end

  check("add: no duplicate for existing category",
    count == 1,
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- With the private tag format preferred, adding normalizes a
  -- legacy duplicate.
  prefs["mediawiki/category_tag"] = "dtMediaWiki|category|"
  local A = make_image("O.jpg")
  attach(A, "Category:Foo")

  select({ A })
  category_add_entry.text = "Foo"
  category_add_button.clicked_callback()

  check("add: normalizes legacy duplicate to preferred format",
    has_tag(A, "dtMediaWiki|category|Foo")
    and not has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")

  prefs["mediawiki/category_tag"] = nil
end

do
  -- Remove via the panel detaches the selected category.
  local A = make_image("P.jpg")
  attach(A, "Category:Foo")
  attach(A, "Category:Bar")

  select({ A })

  -- The selector is rebuilt on refresh: sorted union,
  -- index 1 = Bar.
  check("remove: selector lists the categories",
    category_remove_selector[1] == "Bar"
    and category_remove_selector[2] == "Foo"
    and #category_remove_selector == 2,
    "selector: [" .. tostring(category_remove_selector[1])
      .. ", " .. tostring(category_remove_selector[2]) .. "]")

  category_remove_selector.selected = 1
  category_remove_button.clicked_callback()

  check("remove: detaches the selected category",
    not has_tag(A, "Category:Bar")
    and has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Remove without a selection is a no-op.
  local A = make_image("Q.jpg")
  attach(A, "Category:Foo")

  select({ A })
  category_remove_selector.selected = 0
  category_remove_button.clicked_callback()

  check("remove: no selection is a no-op",
    has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Remove detaches the category in either tag format.
  local A = make_image("R.jpg")
  attach(A, "dtMediaWiki|category|Foo")
  attach(A, "Category:Bar")

  select({ A })
  category_remove_selector.selected = 1  -- Bar
  category_remove_button.clicked_callback()
  category_remove_selector.selected = 1  -- Foo (list rebuilt)
  category_remove_button.clicked_callback()

  check("remove: detaches private-format tag",
    not has_tag(A, "dtMediaWiki|category|Foo")
    and not has_tag(A, "Category:Bar"),
    "A tags: [" .. tag_names(A) .. "]")
end

-----------------------------------------------------------------------
-- Multiple images
-----------------------------------------------------------------------

do
  -- The view shows the union of the categories of all selected
  -- images.
  local A, B = make_image("S.jpg"), make_image("T.jpg")
  attach(A, "Category:Foo")
  attach(B, "Category:Bar")

  select({ A, B })

  check("multiple selection: view shows the union",
    categories_view.text == "Bar; Foo",
    "view: " .. tostring(categories_view.text))
end

do
  -- Add applies to all selected images, keeping their own
  -- categories.
  local A, B = make_image("U.jpg"), make_image("V.jpg")
  attach(A, "Category:Foo")
  attach(B, "Category:Bar")

  select({ A, B })
  category_add_entry.text = "Baz"
  category_add_button.clicked_callback()

  check("multiple selection: add keeps A's categories",
    has_tag(A, "Category:Foo") and has_tag(A, "Category:Baz"),
    "A tags: [" .. tag_names(A) .. "]")

  check("multiple selection: add keeps B's categories",
    has_tag(B, "Category:Bar") and has_tag(B, "Category:Baz"),
    "B tags: [" .. tag_names(B) .. "]")
end

do
  -- Remove applies to all selected images.
  local A, B = make_image("W.jpg"), make_image("X.jpg")
  attach(A, "Category:Foo")
  attach(B, "Category:Foo")
  attach(B, "Category:Bar")

  select({ A, B })
  category_remove_selector.selected = 1  -- Bar
  category_remove_button.clicked_callback()

  check("multiple selection: remove from all",
    not has_tag(A, "Category:Bar")
    and not has_tag(B, "Category:Bar")
    and has_tag(A, "Category:Foo")
    and has_tag(B, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "] "
      .. "B tags: [" .. tag_names(B) .. "]")
end

-----------------------------------------------------------------------
-- Refresh button
-----------------------------------------------------------------------

do
  -- The display goes stale after the tags are edited in the
  -- native tag editor (darktable exposes no tag-changed event to
  -- Lua). The refresh button re-reads the library.
  local A = make_image("AA.jpg")
  attach(A, "Category:Foo")

  select({ A })
  attach(A, "Category:Bar")

  check("refresh: view is stale after a native edit",
    categories_view.text == "Foo",
    "view: " .. tostring(categories_view.text))

  category_refresh_button.clicked_callback()

  check("refresh: view shows the library state",
    categories_view.text == "Bar; Foo",
    "view: " .. tostring(categories_view.text))
end

do
  -- The refresh button saves, not discards, unsaved edits of
  -- other fields.
  local A = make_image("BB.jpg")
  attach(A, "Category:Foo")

  select({ A })
  title_widget.text = "Edited"
  attach(A, "Category:Bar")
  category_refresh_button.clicked_callback()

  check("refresh: keeps unsaved title edit",
    A.title == "Edited",
    "A.title: " .. tostring(A.title))

  check("refresh: view updated",
    categories_view.text == "Bar; Foo",
    "view: " .. tostring(categories_view.text))
end

-----------------------------------------------------------------------
-- Other fields
-----------------------------------------------------------------------

do
  -- An unsaved edit of another field is flushed when a category
  -- operation re-populates the widgets.
  local A = make_image("Y.jpg")

  select({ A })
  title_widget.text = "New Title"
  category_add_entry.text = "Foo"
  category_add_button.clicked_callback()

  check("add: flushes pending title edit",
    A.title == "New Title",
    "A.title: " .. tostring(A.title))

  check("add: attaches Category:Foo",
    has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")
end

do
  -- Editing a different field does not touch the categories.
  local A = make_image("Z.jpg")
  attach(A, "Category:Foo")

  select({ A })
  title_widget.text = "New Title"
  MetadataUI.save()

  check("title edit sets the title",
    A.title == "New Title",
    "A.title: " .. tostring(A.title))

  check("title edit keeps Category:Foo",
    has_tag(A, "Category:Foo"),
    "A tags: [" .. tag_names(A) .. "]")
end

-----------------------------------------------------------------------
-- Summary
-----------------------------------------------------------------------

print(string.format("%d passed, %d failed", passed, failed))

if failed > 0 then
  os.exit(1)
end
