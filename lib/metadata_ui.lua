--[[
  dtMediaWiki Commons metadata UI
  -- dtMediaWiki metadata editor
]]

local dt = require "darktable"

local i18n =
  require "contrib/dtMediaWiki/lib/i18n"

local _ =
  i18n.translate

local presets =
  require "contrib/dtMediaWiki/lib/presets"

local preset_data =
  presets.load()

local preset_names = {}

local preset_editor

for _, preset in ipairs(preset_data) do
  table.insert(
    preset_names,
    preset.name
  )
end

local placeholders =
  require "contrib/dtMediaWiki/lib/placeholders"

local MediaWikiApi =
  require "contrib/dtMediaWiki/lib/mediawikiapi"

local M = {}

local MULTIPLE =
  _("<multiple values>")

local updating = false

-- Images whose metadata is currently displayed in the UI.
local loaded_images = {}

-- Metadata copied from one image.
local metadata_clipboard = nil

-----------------------------------------------------------------------
-- Placeholder selector
-----------------------------------------------------------------------

local placeholder_defs =
  placeholders.list_enabled()

local placeholder_entries = {}
local placeholder_names = {}

for _, def in ipairs(placeholder_defs) do

  local display =
    tostring(def.group) ..
    " — <" ..
    tostring(def.name) ..
    ">"

  table.insert(
    placeholder_entries,
    display
  )

  table.insert(
    placeholder_names,
    def.name
  )
end

-----------------------------------------------------------------------
-- Widgets
-----------------------------------------------------------------------

local preset_selector =
  dt.new_widget("combobox") {
    label = _("Metadata preset"),
    tooltip =
      _("Select metadata preset")
  }

local preset_editor_name =
  dt.new_widget("entry") {
    text = "",
    tooltip = _("Metadata preset name")
  }

local function create_metadata_widget(field)

  local widget_type =
    field.widget or "text_view"

  if widget_type == "entry" then

    return dt.new_widget("entry") {
      text = "",
      tooltip = field.label
    }
  end

  return dt.new_widget("text_view") {
    text = "",
    editable = true,
    tooltip = field.label
  }
end

local preset_editor_widgets = {}

for _, field in ipairs(
  placeholders.list_metadata_fields()
) do

  if field.preset then

    preset_editor_widgets[field.name] =
    create_metadata_widget(field)
  end
end

for _, name in ipairs(preset_names) do
  preset_selector[
    #preset_selector + 1
  ] = name
end

local status =
  dt.new_widget("label") {
    label = _("No image selected")
  }

-----------------------------------------------------------------------
-- Metadata widgets
-----------------------------------------------------------------------

local title_widget =
  dt.new_widget("entry") {
    text = "",
    tooltip = _("Darktable image title")
  }

local metadata_widgets = {}

for _, field in ipairs(
  placeholders.list_metadata_fields()
) do

  metadata_widgets[field.name] =
    create_metadata_widget(field)
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function selected_images()

  return dt.gui.selection() or {}
end

local function copy_images(images)

  local result = {}

  for _, image in ipairs(images or {}) do
    table.insert(result, image)
  end

  return result
end

local function copy_value(value)

  if type(value) ~= "table" then
    return value
  end

  local result = {}

  for key, item in pairs(value) do
    result[key] = item
  end

  return result
end

local function same_title_value(images)

  if #images == 0 then
    return ""
  end

  local value =
    images[1].title or ""

  for index = 2, #images do

    if (images[index].title or "") ~= value then
      return MULTIPLE
    end
  end

  return value
end

local function split_lines(text)

  local result = {}

  for line in tostring(text or "")
      :gmatch("[^\r\n]+") do

    line =
      line:gsub("^%s+", "")
          :gsub("%s+$", "")

    if line ~= "" then
      table.insert(result, line)
    end
  end

  return result
end

local function join_lines(values)

  return table.concat(
    values or {},
    "\n"
  )
end

local function field_value_to_text(
  field,
  value
)

  if field.multiple then
    return join_lines(value or {})
  end

  return value or ""
end

local function field_text_to_value(
  field,
  text
)

  text = text or ""

  if field.parser == "categories" then

    return placeholders.parse_categories(
      text
    )
  end

  if field.multiple then
    return split_lines(text)
  end

  return text
end

local function same_field_value(
  images,
  field
)

  if #images == 0 then
    return ""
  end

  local first =
    field_value_to_text(
      field,
      placeholders.get_field(
        images[1],
        field.name
      )
    )

  for i = 2, #images do

    local value =
      field_value_to_text(
        field,
        placeholders.get_field(
          images[i],
          field.name
        )
      )

    if value ~= first then
      return MULTIPLE
    end
  end

  return first
end

-- TODO unused, no placeholder selector is wired up in the UI
local function append_placeholder( -- luacheck: ignore
  text_widget,
  selector
)

  local index =
    selector.selected

  if not index or index == 0 then
    return
  end

  local name =
    placeholder_names[index]

  if not name then
    return
  end

  local token =
    "<" .. name .. ">"

  local current =
    text_widget.text or ""

  if current == MULTIPLE then
    current = ""
  end

  text_widget.text =
    current .. token

  -- Return combobox to neutral state.
  selector.selected = 0
end

local function selected_preset()

  local index =
    preset_selector.selected

  if not index or index == 0 then
    return nil
  end

  return preset_data[index]
end

local function load_preset_into_editor(preset)

  if not preset then
    return
  end

  preset_editor_name.text =
    preset.name or ""

  local image =
    preset.image or {}

  for _, field in ipairs(
    placeholders.list_metadata_fields()
  ) do

    if field.preset then

      local field_widget =
        preset_editor_widgets[field.name]

      if field_widget then

        local value =
          image[field.name]

        if value == nil then
          value = ""
        end

        if type(value) == "table" then
          value = join_lines(value)
        end

        field_widget.text =
          tostring(value)
      end
    end
  end
end

local function rebuild_preset_selector(
  selected_name
)

  -- Remove existing entries.
  while #preset_selector > 0 do
    preset_selector[#preset_selector] = nil
  end

  local selected_index = 0

  for index, preset in ipairs(preset_data) do

    preset_selector[index] =
      preset.name

    if preset.name == selected_name then
      selected_index = index
    end
  end

  preset_selector.selected =
    selected_index
end

local function save_loaded_metadata()

  if updating then
    return
  end

  if #loaded_images == 0 then
    return
  end

  local title =
    title_widget.text or ""

  if title ~= MULTIPLE then

    for _, image in ipairs(
      loaded_images
    ) do
      image.title = title
    end
  end

  for _, field in ipairs(
    placeholders.list_metadata_fields()
  ) do

    local field_widget =
      metadata_widgets[field.name]

    if field_widget then

      local text =
        field_widget.text or ""

      -- MULTIPLE means that the selected images originally had
      -- different values. Do not overwrite them unless the user
      -- explicitly enters a replacement value.
      if text ~= MULTIPLE then

        local value =
          field_text_to_value(
            field,
            text
          )

        for _, image in ipairs(
          loaded_images
        ) do

          placeholders.set_field(
            image,
            field.name,
            value
          )
        end
      end
    end
  end
end

-- Widgets have no change callbacks, so edits must be flushed
-- explicitly before anything reads or overwrites the metadata.
M.save = save_loaded_metadata

-----------------------------------------------------------------------
-- Apply metadata preset
-----------------------------------------------------------------------

local function clear_preset_editor()

  preset_editor_name.text = ""

  for _, field in ipairs(
    placeholders.list_metadata_fields()
  ) do

    if field.preset then

      local field_widget =
        preset_editor_widgets[field.name]

      if field_widget then
        field_widget.text = ""
      end
    end
  end
end

local function apply_preset()

  local index =
    preset_selector.selected

  if not index or index == 0 then
    return
  end

  local preset =
    preset_data[index]

  if not preset then
    return
  end

  local image_data =
    preset.image

  if not image_data then
    dt.print(
      _("dtMediaWiki: preset contains no image metadata")
    )
    return
  end

  local images =
    selected_images()

  if #images == 0 then
    dt.print(
      _("dtMediaWiki: no image selected")
    )
    return
  end

  save_loaded_metadata()

  for _, image in ipairs(images) do

    for _, field in ipairs(
      placeholders.list_metadata_fields()
    ) do

    if field.preset then

      local preset_value =
        image_data[field.name]

      if preset_value ~= nil
          and preset_value ~= "" then

        if field.preset_apply == "if_empty" then

          local current =
            placeholders.get_field(
              image,
              field.name
            )

          if current == nil
              or current == ""
              or (type(current) == "table"
                  and #current == 0) then

            local value =
              preset_value

            if field.multiple
                and type(value) ~= "table" then

              value =
                field_text_to_value(
                  field,
                  value
                )
            end

            placeholders.set_field(
              image,
              field.name,
              value
            )
          end

        elseif field.preset_apply == "add" then

          local additions =
            preset_value

          if type(additions) ~= "table" then

            additions =
              field_text_to_value(
                field,
                additions
              )
          end

          local current =
            placeholders.get_field(
              image,
              field.name
            ) or {}

          local seen = {}

          for _, value in ipairs(current) do
            seen[value] = true
          end

          for _, value in ipairs(additions) do

            if not seen[value] then

              table.insert(
                current,
                value
              )

              seen[value] = true
            end
          end

          placeholders.set_field(
            image,
            field.name,
            current
          )
          end
        end
      end
    end
  end

  M.refresh()

end

local function edit_preset()

  local preset =
    selected_preset()

  if preset then
    load_preset_into_editor(
      preset
    )
  else
    clear_preset_editor()
  end

  preset_editor.visible = true
end

local function save_preset()

  local name =
    preset_editor_name.text or ""

  name =
    name:gsub("^%s+", "")
        :gsub("%s+$", "")

  if name == "" then
    dt.print(
      _("dtMediaWiki: the preset needs a name")
    )
    return
  end

  local preset =
    presets.find(
      preset_data,
      name
    )

  if not preset then

    preset = {
      name = name,
      image = {}
    }

    table.insert(
      preset_data,
      preset
    )
  end

  preset.name = name
  preset.image =
    preset.image or {}

  for _, field in ipairs(
    placeholders.list_metadata_fields()
  ) do

    if field.preset then

      local field_widget =
        preset_editor_widgets[field.name]

      if field_widget then

        preset.image[field.name] =
          field_widget.text or ""
      end
    end
  end

  local ok, err =
    presets.save(
      preset_data
    )

if not ok then

  local message =
    string.format(
      _("dtMediaWiki: preset could not be saved: %s"),
      tostring(err)
    )

  dt.print(message)

  local f =
    io.open(
      MediaWikiApi.temp_file("preset-save-error.txt"),
      "w"
    )

  if f then

    f:write(
      message,
      "\n\n"
    )

    f:write(
      "preset file: ",
      tostring(presets.get_file()),
      "\n"
    )

    f:close()
  end

  return
end

  rebuild_preset_selector(
    name
  )

  dt.print(
    string.format(
      _("dtMediaWiki: preset saved: %s"),
      name
    )
  )
end

local function new_preset()

  clear_preset_editor()

  preset_editor.visible = true
end

-----------------------------------------------------------------------
-- Refresh UI from selection
-----------------------------------------------------------------------

function M.refresh()

  if updating then
    return
  end

  updating = true

  local images =
    selected_images()

  if #images == 0 then

    title_widget.text = ""
    status.label =
     _("No image selected")

    for _, field in ipairs(
      placeholders.list_metadata_fields()
    ) do

    local field_widget =
      metadata_widgets[field.name]

    if field_widget then
      field_widget.text = ""
    end
end

loaded_images = {}

    updating = false
    return
  end

  if #images == 1 then

    status.label =
      tostring(images[1].filename)

  else

    status.label =
      string.format(
        _("%d images selected"),
	#images
      )
  end

  title_widget.text =
    same_title_value(images)

for _, field in ipairs(
  placeholders.list_metadata_fields()
) do

  local field_widget =
    metadata_widgets[field.name]

  if field_widget then

    field_widget.text =
      same_field_value(
        images,
        field
      )
  end
end

  loaded_images =
    copy_images(images)

  updating = false
end

-----------------------------------------------------------------------
-- Copy / paste Commons metadata
-----------------------------------------------------------------------

local function copy_metadata()

  -- First save possible edits still visible in the editor.
  save_loaded_metadata()

  local images =
    selected_images()

  if #images ~= 1 then

    dt.print(
      _("dtMediaWiki: select exactly one source image")
    )

    return
  end

  local image =
    images[1]

  local clipboard = {}

  for _, field in ipairs(
    placeholders.list_metadata_fields()
  ) do

    clipboard[field.name] =
      copy_value(
        placeholders.get_field(
          image,
          field.name
        )
      )
  end

  metadata_clipboard =
    clipboard

  dt.print(
    _("dtMediaWiki: metadata copied")
  )
end


local function paste_metadata()

  if not metadata_clipboard then

    dt.print(
      _("dtMediaWiki: no copied metadata available")
    )

    return
  end

  local images =
    selected_images()

  if #images == 0 then

    dt.print(
      _("dtMediaWiki: no image selected")
    )

    return
  end

  save_loaded_metadata()

  for _, image in ipairs(images) do

    for _, field in ipairs(
      placeholders.list_metadata_fields()
    ) do

      placeholders.set_field(
        image,
        field.name,
        copy_value(
          metadata_clipboard[field.name]
        )
      )
    end
  end

  M.refresh()

  dt.print(
    string.format(
      _("dtMediaWiki: metadata pasted to %d image(s)"),
      #images
    )
  )
end

-----------------------------------------------------------
-- Buttons
-----------------------------------------------------------------------

local preset_edit_button =
  dt.new_widget("button") {
    label = _("Edit preset"),
    clicked_callback = edit_preset
  }

local preset_new_button =
  dt.new_widget("button") {
    label = _("New preset"),
    clicked_callback = new_preset
  }

local preset_save_button =
  dt.new_widget("button") {
    label = _("Save"),
    clicked_callback = save_preset
  }

local preset_close_button =
  dt.new_widget("button") {
    label = _("Close"),

    clicked_callback = function()
      preset_editor.visible = false
    end
  }

local apply_preset_button =
  dt.new_widget("button") {
    label = _("Apply preset"),
    clicked_callback = apply_preset
  }

local copy_metadata_button =
  dt.new_widget("button") {
    label = _("Copy metadata"),
    clicked_callback = copy_metadata
  }

local paste_metadata_button =
  dt.new_widget("button") {
    label = _("Paste metadata"),
    clicked_callback = paste_metadata
  }

-----------------------------------------------------------------------
--- Preset Editor
-----------------------------------------------------------------------

local preset_editor_definition = {}

table.insert(
  preset_editor_definition,
  dt.new_widget("label") {
    label = _("Edit metadata preset")
  }
)

-- Preset name
table.insert(
  preset_editor_definition,
  dt.new_widget("box") {
    orientation = "horizontal",

    dt.new_widget("label") {
      label = _("Name")
    },

    preset_editor_name
  }
)

-- Metadata fields
for _, field in ipairs(
  placeholders.list_metadata_fields()
) do

  if field.preset then

    local field_widget =
      preset_editor_widgets[field.name]

    if field_widget then

      table.insert(
        preset_editor_definition,
        dt.new_widget("box") {
          orientation = "horizontal",

          dt.new_widget("label") {
            label = field.label,
			halign = "start"
          },

          field_widget
        }
      )
    end
  end
end

local preset_editor_button_box =
  dt.new_widget("box") {
    orientation = "horizontal",
    preset_new_button,
    preset_save_button
  }

table.insert(
  preset_editor_definition,
  preset_editor_button_box
)

table.insert(
  preset_editor_definition,
  preset_close_button
)

preset_editor =
  dt.new_widget("box")(
    preset_editor_definition
  )

preset_editor.visible = false

local metadata_editor_definition = {
  orientation = "vertical"
}

table.insert(
  metadata_editor_definition,
  dt.new_widget("box") {
    orientation = "horizontal",

    dt.new_widget("label") {
      label = _("Title"),
      halign = "start"
    },

    title_widget
  }
)

for _, field in ipairs(
  placeholders.list_metadata_fields()
) do

  local field_widget =
    metadata_widgets[field.name]

  if field_widget then

    table.insert(
      metadata_editor_definition,
      dt.new_widget("box") {
        orientation = "horizontal",

        dt.new_widget("label") {
          label = field.label,
          halign = "start"
        },

        field_widget
      }
    )
  end
end

local metadata_editor =
  dt.new_widget("box")(
    metadata_editor_definition
  )

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

local widget =
  dt.new_widget("box") {
    orientation = "vertical",

    status,

    dt.new_widget("box") {
      orientation = "horizontal",
      preset_selector
    },

    dt.new_widget("box") {
      orientation = "horizontal",
      apply_preset_button,
      preset_edit_button
    },

    preset_editor,

    dt.new_widget("box") {
      orientation = "horizontal",
      copy_metadata_button,
      paste_metadata_button
    },

    metadata_editor

  }

-----------------------------------------------------------------------
-- Register module
-----------------------------------------------------------------------

dt.register_lib(
  "dtmediawiki_metadata",
  _("Wikimedia Commons metadata"),
  true,   -- expandable
  false,  -- resettable

  {
    [dt.gui.views.lighttable] = {
      "DT_UI_CONTAINER_PANEL_RIGHT_CENTER",
      100
    }
  },

  widget,

  function()
    M.refresh()
  end,

  function()
  end
)

-----------------------------------------------------------------------
-- Follow image selection
-----------------------------------------------------------------------

dt.register_event(
  "dtmediawiki_metadata_selection",
  "selection-changed",
  function()

    -- Save metadata belonging to the previous selection.
    save_loaded_metadata()

    -- Load metadata belonging to the new selection.
    M.refresh()

  end
)

M.widget = widget

return M
