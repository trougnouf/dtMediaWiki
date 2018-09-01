--[[dtMediaWiki is a fork of LrMediaWiki for darktable
    Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>

LrMediaWiki authors:
Robin Krahl <robin.krahl@wikipedia.de>
Eckhard Henkel <eckhard.henkel@wikipedia.de>

Dependencies:
* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-multipart-post: HTTP Multipart Post helper for lua
* lua-luajson: JSON parser/encoder for Lua
* darktable-lua-scripts-git: Lua scripts extending darktable
]]
-- print: require 'pl.pretty'.dump(t)

local dt = require "darktable"
local df = require "lib/dtutils.file"
local gettext = dt.gettext

dt.preferences.register("mediawiki_export", "username", "string", "Wikimedia username", "Wikimedia Commons username", "")
dt.preferences.register("mediawiki_export", "password", "string", "Wikimedia password",
        "Wikimedia Commons password (to be stored in plain-text!)", "")

local mediawikiapi = require "contrib/dtMediaWiki/mediawikiapi"

local function msgout(txt)
  print(txt)
  dt.print(txt)
end


local function make_image_page(image)
  local imgpg = {"=={{int:filedesc}}==\n{{Information"}
  local desc = image.description -- TODO detect international desc
  if image.description == '' then desc = image.title end
  table.insert(imgpg, "|description={{en|1="..desc.."}}")
  table.insert(imgpg, "|date="..image.exif_datetime_taken) --TODO check format
  table.insert(imgpg, "|source={{own}}")
  local username = dt.preferences.read("mediawiki_export", "username", "string")
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
    end
  end
  imgpg = table.concat(imgpg, "\n")
  return imgpg
end

--This function is called once for each exported image
local function register_storage_store(storage, image, format, filename, number, total, high_quality, extra_data)
  print(make_image_page(image))
  msgout("exported " .. filename) -- that is the path also
end

--This function is called once all images are processed and all store calls are finished.
local function register_storage_finalize(storage, image_table, extra_data)
  local fcnt = 0
  for _ in pairs(image_table) do fcnt = fcnt + 1 end
  msgout("exported "..fcnt.."/"..extra_data["init_img_cnt"].." images to mediawiki")
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
  out_images = {}
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

if(MediaWikiApi.login(dt.preferences.read("mediawiki_export", "username", "string"), dt.preferences.read("mediawiki_export", "password", "string"))) then
    dt.register_storage("mediawiki_export", "Wikimedia Commons", register_storage_store, register_storage_finalize, register_storage_supported, register_storage_initialize)
else
    msgout("Unable to log into Wikimedia Commons, export disabled.")
end



--[[
LrMediaWiki license:
Copyright (c) 2014, 2015, 2016 by the LrMediaWiki team, X11 License

Except:
- JSON.lua: Copyright 2010-2014 Jeffrey Friedl [1], CC-by 3.0 [2]

[0] <https://raw.githubusercontent.com/ireas/LrMediaWiki/master/CREDITS.txt>
[1] <http://regex.info/blog/lua/json>
[2] <http://creativecommons.org/licenses/by/3.0/deed.en_US>

The X11 License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.]]
