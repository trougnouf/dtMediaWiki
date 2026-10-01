--[[
  dtMediaWiki Commons category search
  -- search Wikimedia Commons categories and add them to the
     selected images
]]

local dt = require "darktable"

local i18n =
  require "contrib/dtMediaWiki/lib/i18n"

local _ =
  i18n.translate

local placeholders =
  require "contrib/dtMediaWiki/lib/placeholders"

local MediaWikiApi =
  require "contrib/dtMediaWiki/lib/mediawikiapi"

local MetadataUI =
  require "contrib/dtMediaWiki/lib/metadata_ui"

local M = {}

-- darktable has no list widget, so results are shown in a fixed
-- pool of buttons which are relabeled and shown/hidden per search.
local MAX_RESULTS = 15

-- Category names of the currently shown result buttons.
local results = {}

-----------------------------------------------------------------------
-- Widgets
-----------------------------------------------------------------------

local search_entry =
  dt.new_widget("entry") {
    text = "",
    placeholder = _("Search Commons categories"),
    tooltip = _("Search terms, eg: cemetery innsbruck")
  }

local status =
  dt.new_widget("label") {
    label = ""
  }

local result_box =
  dt.new_widget("box") {
    orientation = "vertical"
  }

-----------------------------------------------------------------------
-- Add category to selected images
-----------------------------------------------------------------------

local function add_category(category)

  local images =
    dt.gui.selection() or {}

  if #images == 0 then
    dt.print(_("No image selected"))
    return
  end

  -- Flush pending edits of the metadata editor first, otherwise
  -- they would be lost when the refresh below re-populates the
  -- widgets.
  MetadataUI.save()

  local count = 0

  for _, image in ipairs(images) do

    local categories =
      placeholders.get_categories(image)

    local present = false

    for _, existing in ipairs(categories) do
      if existing == category then
        present = true
        break
      end
    end

    if not present then

      -- add_category only touches this one category, so tags
      -- attached elsewhere (e.g. in the native tag editor) are
      -- never dropped.
      placeholders.add_category(
        image,
        category
      )

      count = count + 1
    end
  end

  MetadataUI.refresh()

  dt.print(
    string.format(
      _("Added [[Category:%s]] to %d image(s)"),
      category,
      count
    )
  )
end

-----------------------------------------------------------------------
-- Open category in web browser
-----------------------------------------------------------------------

local is_windows =
  package.config:sub(1, 1) == "\\"

local function category_url(category)

  -- Encode everything except unreserved characters, so the URL
  -- contains no shell metacharacters.
  local title =
    ("Category:" .. category)
      :gsub(" ", "_")
      :gsub("[^%w%-%._~:]", function(c)
        return string.format("%%%02X", string.byte(c))
      end)

  return "https://commons.wikimedia.org/wiki/" .. title
end

local function open_category(category)

  local url =
    category_url(category)

  local command

  if is_windows then
    command = 'start "" "' .. url .. '"'
  elseif dt.configuration.running_os == "macos" then
    command = "open '" .. url .. "'"
  else
    command = "xdg-open '" .. url .. "' >/dev/null 2>&1 &"
  end

  os.execute(command)
end

-----------------------------------------------------------------------
-- Result buttons
-----------------------------------------------------------------------

-- Each result row consists of an add button and an open button.
local result_rows = {}

for i = 1, MAX_RESULTS do

  local add_button =
    dt.new_widget("button") {
      label = "",

      clicked_callback = function()
        if results[i] then
          add_category(results[i])
        end
      end
    }

  local open_button =
    dt.new_widget("button") {
      label = "↗",
      tooltip = _("Open category in web browser"),

      clicked_callback = function()
        if results[i] then
          open_category(results[i])
        end
      end
    }

  local row =
    dt.new_widget("box") {
      orientation = "horizontal",
      visible = false,
      add_button,
      open_button
    }

  result_rows[i] = {
    row = row,
    add_button = add_button
  }

  result_box[#result_box + 1] = row
end

local function show_results(categories)

  results = categories

  for i, result_row in ipairs(result_rows) do

    local category = categories[i]

    if category then
      result_row.add_button.label = category
      result_row.add_button.tooltip = string.format(
        _("Add [[Category:%s]] to the selected images"),
        category
      )
      result_row.row.visible = true
    else
      result_row.add_button.label = ""
      result_row.row.visible = false
    end
  end
end

-----------------------------------------------------------------------
-- Search
-----------------------------------------------------------------------

local function search()

  local term =
    tostring(search_entry.text or "")
      :gsub("^%s+", "")
      :gsub("%s+$", "")

  if term == "" then
    return
  end

  status.label = _("Searching…")

  local ok, categories =
    pcall(
      MediaWikiApi.searchCategories,
      term,
      MAX_RESULTS
    )

  if not ok then
    show_results({})
    status.label = _("Search failed")
    dt.print(tostring(categories))
    return
  end

  categories = categories or {}

  show_results(categories)

  if #categories == 0 then
    status.label = _("No categories found")
  else
    status.label = _("Click a category to add it to the selected images")
  end
end

local search_button =
  dt.new_widget("button") {
    label = _("Search"),
    clicked_callback = search
  }

local widget =
  dt.new_widget("box") {
    orientation = "vertical",

    dt.new_widget("box") {
      orientation = "horizontal",
      search_entry,
      search_button
    },

    status,
    result_box
  }

-----------------------------------------------------------------------
-- Register module
-----------------------------------------------------------------------

dt.register_lib(
  "dtmediawiki_category_search",
  _("Wikimedia Commons category search"),
  true,   -- expandable
  false,  -- resettable

  {
    [dt.gui.views.lighttable] = {
      "DT_UI_CONTAINER_PANEL_RIGHT_CENTER",
      99
    }
  },

  widget,

  function()
  end,

  function()
  end
)

M.widget = widget

return M
