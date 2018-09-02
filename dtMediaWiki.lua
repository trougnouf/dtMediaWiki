--[[dtMediaWiki is a darktable plugin which exports images to Wikimedia Commons
    Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>

Dependencies:
* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-luajson: JSON parser/encoder for Lua
]]

local dt = require "darktable"
local gettext = dt.gettext
local mediawikiapi = require "contrib/dtMediaWiki/mediawikiapi"

-- Preference entries
dt.preferences.register(
  "mediawiki", "username", "string", "Wikimedia username","Wikimedia Commons username",
  "")
dt.preferences.register(
  "mediawiki", "password", "string", "Wikimedia password",
  "Wikimedia Commons password (to be stored in plain-text!)", "")
dt.preferences.register(
  "mediawiki", "overwrite", "bool", "Commons: Overwrite existing images?",
  "Existing images will be overwritten  without confirmation, otherwise the upload will fail.",
  false)
dt.preferences.register(
  "mediawiki", "cat_cam", "bool", "Commons: Categorize camera?",
  "A category will be added with the camera information (eg: [[Category:Taken with Fujifilm X-E2 and XF18-55mmF2.8-4 R LM OIS]])",
  false)
dt.preferences.register(
  "mediawiki", "namepattern", "string", "Commons: Preferred naming pattern",
  'Determines the File: page name, variables are $TITLE, $FILE_NAME, and $DESCRIPTION. Note that $TITLE or $DESCRIPTION is required, and if both are chosen but only one is available then the fallback name will be "$AVAILABLEINFO ($FILE_NAME)"', "$TITLE ($FILE_NAME) $DESCRIPTION")
dt.preferences.register(
  "mediawiki", "titleindesc", "bool", "Commons: Use title in description",
  "Use the title in description if both are available: description={{en|1=$TITLE: $DESCRIPTION}}", true)

local function msgout(txt)
  print(txt)
  dt.print(txt)
end

-- Generate image name
local function make_image_name(image, tmp_exp_path)
  local basename = image.filename:match"[^.]+"
  local outname = dt.preferences.read("mediawiki", "namepattern", "string")
  if image.title ~= "" and image.description ~= "" then --2 items available
    outname = outname:gsub("$TITLE", image.title)
    outname = outname:gsub("$FILE_NAME", basename)
    outname = outname:gsub("$DESCRIPTION", image.description)
  else
    local presdata = image.title..image.description
    local user_req = dt.preferences.read("mediawiki", "namepattern", "string")
    if user_req:find("$TITLE") and user_req:find("$DESCRIPTION") then
      outname = presdata.." ("..basename..")"
    else
      outname = outname:gsub("$TITLE", presdata)
      outname = outname:gsub("$FILE_NAME", basename)
      outname = outname:gsub("$DESCRIPTION", presdata)
    end
  end
  local ext = tmp_exp_path:match"[^.]+$"
  return outname.."."..ext
end

-- Round to 1 decimal, remove useless .0's and convert number to string
local function fmt_flt(num)
  num = math.floor(num*10+.5)/10
  if string.sub(num, -2) == '.0' then return string.sub(num,1,-3)
  else return tostring(num)
  end
end

local function get_description(image)
  if dt.preferences.read("mediawiki", "titleindesc", "bool") and image.description~="" and image.title ~= "" then
    return image.title..": "..image.description
  elseif image.description~="" then return image.description
  else return image.title
  end
end

-- Generate an image page with all required info from tags, metadata, and such.
local function make_image_page(image)
  local imgpg = {"=={{int:filedesc}}==\n{{Information"}
  table.insert(imgpg, "|description={{en|1="..get_description(image).."}}")
  table.insert(imgpg, "|date="..image.exif_datetime_taken) --TODO check format
  table.insert(imgpg, "|source={{own}}")
  local username = dt.preferences.read("mediawiki", "username", "string")
  if image.creator == '' then
    table.insert(imgpg, "|author=[[User:"..username.."|"..username.."]]")
  else
    table.insert(imgpg, "|author=[[User:"..username.."|"..image.creator.."]]")
  end
  table.insert(imgpg, "}}")
  if image.latitude ~= nil and image.longitude ~= nil then
    table.insert(imgpg, "{{Location |1="..image.latitude.." |2="..image.longitude.." }}")
  end
  table.insert(imgpg, "=={{int:license-header}}==")
  table.insert(imgpg, "{{self|"..image.rights.."}}")
  for i,tag in pairs(dt.tags.get_tags(image)) do
    local tag = tag.name
    if string.sub(tag, 1, 9)=="Category:" then
      table.insert(imgpg, "[["..tag.."]]")
    elseif tag:sub(1,2)=="{{" then table.insert(imgpg, tag)
    end
  end
  if dt.preferences.read("mediawiki", "cat_cam", "bool") then
    print("catcam enabled")--dbg
    local catcam = ""
    if image.exif_model ~= '' then
      local model = image.exif_maker:sub(1,1)..image.exif_maker:sub(2):lower()
      catcam = "[[Category:Taken with "..model.." "..image.exif_model
      if image.exif_lens ~= '' then
        catcam = catcam.." and "..image.exif_lens.."]]"
      else catcam = catcam.."]]"
      end
      table.insert(imgpg, catcam)
    end
    if image.exif_aperture then
      table.insert(imgpg, "[[Category:F-number f/"..fmt_flt(image.exif_aperture).."]]")
    end
    if image.exif_focal_length ~= "" then
      table.insert(imgpg, "[[Category:Lens focal length "..fmt_flt(image.exif_focal_length).." mm]]")
    end
    if image.exif_iso ~= "" then
      table.insert(imgpg, "[[Category:ISO speed rating "..fmt_flt(image.exif_iso).."]]")
    end
--    if image.exif_exposure ~= "" then
--      table.insert(imgpg, "[[Category:Exposure time "..image.exif_exposure.." sec]]")
--    end -- decimal instead of fraction (TODO)
  end
  table.insert(imgpg, "[[Category:Uploaded with dtMediaWiki]]")
  imgpg = table.concat(imgpg, "\n")
  return imgpg
end

--This function is called once for each exported image
local function register_storage_store(storage, image, format, tmp_exp_path, number, total, high_quality, extra_data)
  local imagepage = make_image_page(image)
  local imagename = make_image_name(image, tmp_exp_path)
  --print(imagepage)
  MediaWikiApi.uploadfile(tmp_exp_path, imagepage, imagename, dt.preferences.read("mediawiki", "overwrite", "bool"))
  msgout("exported " .. imagename) -- that is the path also
end

--This function is called once all images are processed and all store calls are finished.
local function register_storage_finalize(storage, image_table, extra_data)
  local fcnt = 0
  for _ in pairs(image_table) do fcnt = fcnt + 1 end
  msgout("exported "..fcnt.."/"..extra_data["init_img_cnt"].." images to Wikimedia Commons")
end

--A function called to check if a given image format is supported by the Lua storage; this is used to build the dropdown format list for the GUI.
local function register_storage_supported(storage, format)
    if format.extension == "jpg" or format.extension == "png"
            or format.extension == "tif" or format.extension == "webp" then
        return true
    end
    return false
end

--A function called before storage happens
--This function can change the list of exported functions
local function register_storage_initialize(storage, format, images, high_quality, extra_data)
  local out_images = {}
  for i,img in pairs(images) do
    if img.rights == '' then
      msgout("Error: "..img.path.." has no rights, cannot be exported to Wikimedia Commons") --TODO check allowed formats
      goto post_insertion
    elseif img.title == '' and img.description == '' then
      msgout("Error: "..img.path.." is missing a meaningful title and/or description, won't be exported to Wikimedia Commons")
      goto post_insertion
    end
    table.insert(out_images, img)
    ::post_insertion::
  end
  extra_data["init_img_cnt"] = #images
  return out_images
end

-- Darktable target storage entry

if MediaWikiApi.login(
  dt.preferences.read("mediawiki", "username", "string"),
  dt.preferences.read("mediawiki", "password", "string")) then
    dt.register_storage(
      "mediawiki", "Wikimedia Commons", register_storage_store,
      register_storage_finalize, register_storage_supported,
      register_storage_initialize)
else
    msgout("Unable to log into Wikimedia Commons, export disabled.")
end