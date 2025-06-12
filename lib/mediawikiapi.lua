--[[
Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>
Contributor: Simon Legner (simon04)

mediawikiapi.lua uses some code adapted from LrMediaWiki
LrMediaWiki authors:
Robin Krahl <robin.krahl@wikipedia.de>
Eckhard Henkel <eckhard.henkel@wikipedia.de>

Dependencies:
* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-luajson: JSON parser/encoder for Lua
* lua-multipart-post: HTTP Multipart Post helper
  (darktable is not a dependency)
]]
package.path = package.path .. ";/dtMediaWiki/?.lua"
package.path = package.path .. ";/usr/share/darktable/lua/contrib/dtMediaWiki/?.lua"
local https = require "ssl.https"
local json = require "json"
local ltn12 = require "ltn12"
local mpost = require "multipart-post"

local MediaWikiApi = {
  userAgent = string.format("mediawikilua %d.%d", 0, 1),
  apiPath = "https://commons.wikimedia.org/w/api.php",
  cookie = {},
  edit_token = nil
}

local function httpsget(url, reqheaders)
  local res, code, resheaders, _ =
    https.request {
    url = url,
    headers = reqheaders
  }
  resheaders.status = code

  return res, resheaders
end

local function httpspost(url, postBody, reqheaders)
  local res = {}
  local _, code, resheaders, _ =
    https.request {
    url = url,
    method = "POST",
    headers = reqheaders,
    source = ltn12.source.string(postBody),
    sink = ltn12.sink.table(res)
  }
  resheaders.status = code

  return table.concat(res), resheaders
end

local function throwUserError(text)
  print(text)
end

-- parse a received cookie and update MediaWikiApi.cookie
function MediaWikiApi.parseCookie(unparsedcookie_header)
  if not unparsedcookie_header or string.len(unparsedcookie_header) == 0 then return end
  local current_cookie_definitions = unparsedcookie_header
  while current_cookie_definitions and string.len(current_cookie_definitions) > 0 do
    current_cookie_definitions = string.match(current_cookie_definitions, "^%s*(.*)")
    if string.len(current_cookie_definitions) == 0 then break end
    local next_comma_pos = string.find(current_cookie_definitions, ",")
    local single_cookie_def_str, remaining_definitions_after_this = "", ""
    if next_comma_pos then
      single_cookie_def_str = string.sub(current_cookie_definitions, 1, next_comma_pos - 1)
      remaining_definitions_after_this = string.sub(current_cookie_definitions, next_comma_pos + 1)
    else
      single_cookie_def_str = current_cookie_definitions
    end
    single_cookie_def_str = string.match(single_cookie_def_str, "^%s*(.-)%s*$")
    if string.len(single_cookie_def_str) > 0 then
        local semicolon_in_def_pos = string.find(single_cookie_def_str, ";")
        local crumb = semicolon_in_def_pos and string.sub(single_cookie_def_str, 1, semicolon_in_def_pos - 1) or single_cookie_def_str
        crumb = string.match(crumb, "^%s*(.-)%s*$")
        local equals_sep_pos = string.find(crumb, "=")
        if equals_sep_pos then
          local cvar, cval = string.sub(crumb, 1, equals_sep_pos - 1), string.sub(crumb, equals_sep_pos + 1)
          local icvarcomma = string.find(cvar, ",")
          while icvarcomma do cvar, icvarcomma = string.sub(cvar, icvarcomma + 2), string.find(cvar, ",") end
          cvar, cval = string.match(cvar, "^%s*(.-)%s*$"), string.match(cval, "^%s*(.-)%s*$")
          if string.len(cvar) > 0 then MediaWikiApi.cookie[cvar] = cval end
        end
    end
    current_cookie_definitions = remaining_definitions_after_this
  end
end

-- generate a cookie string from MediaWikiApi.cookie to send to server
function MediaWikiApi.cookie2string()
  local prestr = {}
  for cvar, cval in pairs(MediaWikiApi.cookie) do table.insert(prestr, cvar .. "=" .. cval .. ";") end
  return table.concat(prestr)
end

-- Demand an edit token. probably can change this to request only one per session
function MediaWikiApi.getEditToken()
  --if MediaWikiApi.edit_token == nil then
  local arguments = {
    action = "query",
    meta = "tokens",
    type = "csrf",
    format = "json"
  }
  local jsonres = MediaWikiApi.performRequest(arguments)
  MediaWikiApi.edit_token = jsonres.query.tokens.csrftoken
  --end
  return MediaWikiApi.edit_token
end

function MediaWikiApi.uploadfile(filepath, pagetext, filename, overwrite, comment)
  -- Otherwise will fail, see https://github.com/trougnouf/dtMediaWiki/issues/29
  local filename_replaced = string.gsub(string.gsub(filename, "'", ''), '"', '')
  local file_handler = io.open(filepath)
  local content = {
    action = "upload",
    format = "json",
    filename = filename_replaced,
    text = pagetext,
    comment = comment,
    token = MediaWikiApi.getEditToken(),
    file = {
      filename = filename,
      data = file_handler:read("*all")
    }
  }
  if overwrite then
    content["ignorewarnings"] = "true"
  end
  local res = {}
  local req = mpost.gen_request(content)
  req.headers["cookie"] = MediaWikiApi.cookie2string()
  req.url = MediaWikiApi.apiPath
  req.sink = ltn12.sink.table(res)
  local _, _, resheaders = https.request(req)
  local jsonres = json.decode(table.concat(res))
  local success = jsonres.upload.result == 'Success'
  MediaWikiApi.parseCookie(resheaders["set-cookie"])
  return success
end

-- Function to sanitize sensitive information in the string
local function sanitize_output(str)
  -- Replace password and token values with '***'
  str = string.gsub(str, '([\'"]?)(password|token|logintoken)([\'"]?[=|:][\'"]?).-([&,}\"]])', '%1%2%3***%4')
  return str
end

-- Overwrite the trace function to use the sanitize_output function
MediaWikiApi.trace = function(...)
  local args = {...}
  for i, v in ipairs(args) do if type(v) == "string" then args[i] = sanitize_output(v) end end
  print(table.unpack(args))
end

-- Code adapted from LrMediaWiki:

--- URL-encode a string according to RFC 3986.
-- Based on http://lua-users.org/wiki/StringRecipes
-- @param str the string to encode
-- @return the URL-encoded string
function MediaWikiApi.urlEncode(str)
  if str then
    str = string.gsub(str, "\n", "\r\n")
    str =
      string.gsub(
      str,
      "([^%w %-%_%.%~])",
      function(c)
        return string.format("%%%02X", string.byte(c))
      end
    )
    str = string.gsub(str, " ", "+")
  end
  return str
end

--- Convert HTTP arguments to a URL-encoded request body.
-- @param arguments (table) the arguments to convert
-- @return (string) a request body created from the URL-encoded arguments
function MediaWikiApi.createRequestBody(arguments)
  local body = nil
  for key, value in pairs(arguments) do
    if body then
      body = body .. "&"
    else
      body = ""
    end
    body = body .. MediaWikiApi.urlEncode(key) .. "=" .. MediaWikiApi.urlEncode(value)
  end
  return body or ""
end

function MediaWikiApi.performHttpRequest(path, arguments, post) -- changed signature!
  local requestBody = MediaWikiApi.createRequestBody(arguments)
  local requestHeaders = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["User-Agent"] = MediaWikiApi.userAgent
  }
  if post then
    requestHeaders["Content-Length"] = #requestBody
  end
  requestHeaders["Cookie"] = MediaWikiApi.cookie2string()
  MediaWikiApi.trace("Performing HTTP request")
  MediaWikiApi.trace("  Path:", path)
  MediaWikiApi.trace("  Request body:", requestBody)

  local resultBody, resultHeaders
  if post then
    resultBody, resultHeaders = httpspost(path, requestBody, requestHeaders)
  else
    resultBody, resultHeaders = httpsget(path, requestBody, requestHeaders)
  end

  MediaWikiApi.trace("  Result status:", resultHeaders.status)

  if not resultHeaders.status then
    throwUserError("No network connection")
  elseif resultHeaders.status ~= 200 then
    -- Intentionally not calling httpError here, as it doesn't exist in the original file
  end
  MediaWikiApi.parseCookie(resultHeaders["set-cookie"])
  MediaWikiApi.trace("  Result body:", resultBody)
  return resultBody
end

function MediaWikiApi.performRequest(arguments)
  local resultBody = MediaWikiApi.performHttpRequest(MediaWikiApi.apiPath, arguments, true)
  local jsonres = json.decode(resultBody)
  return jsonres
end

function MediaWikiApi.logout()
  -- See https://www.mediawiki.org/wiki/API:Logout
  local arguments = {
    action = "logout"
  }
  MediaWikiApi.performRequest(arguments)
end

function MediaWikiApi.promptFor2FACode(prompt_message)
  print("------------------------------------------------------------------")
  print("-- TWO-FACTOR AUTHENTICATION REQUIRED --")
  print(prompt_message)
  print("Please check your email, then type the verification code here and press Enter:")
  io.stdout:flush()
  local code = io.read()
  print("------------------------------------------------------------------")
  return code
end

function MediaWikiApi.login(username, password)
  -- See https://www.mediawiki.org/wiki/API:Login
  -- Check if the credentials are a main-account or a bot-account.
  -- The different credentials need different login arguments.
  -- The existance of the character "@" inside of an username is an
  -- identicator if the credentials are a bot-account or a main-account.
  local credentials = string.find(username, "@") and "bot-account" or "main-account"
  MediaWikiApi.trace("Credentials: " .. credentials)

  -- Check if a user is logged in:
  local arguments = { action = "query", meta = "userinfo", format = "json" }
  local jsonres = MediaWikiApi.performRequest(arguments)
  local id, name = jsonres.query.userinfo.id, jsonres.query.userinfo.name
  if id ~= 0 and id ~= "0" then
    MediaWikiApi.trace('Logged in as user "' .. name .. '" (ID: ' .. id .. ")")
    if name == username or (credentials == "bot-account" and name == string.match(username, "(.*)@")) then
      MediaWikiApi.trace("No new login needed")
      return true
    end
    MediaWikiApi.trace('Logout and new login needed with username "' .. username .. '".')
    MediaWikiApi.logout()
  else
    MediaWikiApi.trace("Not logged in, need to login")
  end

  -- A login token needs to be retrieved prior of a login action:
  arguments = { action = "query", meta = "tokens", type = "login", format = "json" }
  jsonres = MediaWikiApi.performRequest(arguments)
  local logintoken = jsonres.query.tokens.logintoken

  -- Perform login:
  if credentials == "main-account" then
    arguments = {
      format = "json", action = "clientlogin", loginreturnurl = "https://www.mediawiki.org",
      username = username, password = password, logintoken = logintoken
    }
    while true do
      jsonres = MediaWikiApi.performRequest(arguments)
      local loginResult = jsonres.clientlogin.status
      if loginResult == "PASS" then
        MediaWikiApi.trace("Login successful.")
        return true
      elseif loginResult == "UI" then
        MediaWikiApi.trace("UI interaction required for login: " .. (jsonres.clientlogin.message or "No message"))
        local authRequest = jsonres.clientlogin.requests and jsonres.clientlogin.requests[1]
        
        if authRequest and authRequest.id == "MediaWiki\\Extension\\EmailAuth\\EmailAuthAuthenticationRequest" then
          local two_factor_code = MediaWikiApi.promptFor2FACode(jsonres.clientlogin.message)
          if not two_factor_code or two_factor_code == "" then
            MediaWikiApi.trace("User cancelled 2FA input. Login failed.")
            return false
          end
          
          -- Rebuild the arguments for the continuation request, per the API documentation.
          arguments = {
              action = "clientlogin",
              format = "json",
              logincontinue = "1", -- Must be a string "1", not a boolean
              logintoken = logintoken,
              token = two_factor_code -- The user's 2FA code
          }
        else
          MediaWikiApi.trace("Login failed: Unsupported UI authentication step.")
          return false
        end
      else
        MediaWikiApi.trace('Login failed: ' .. (jsonres.clientlogin.message or "Unknown reason"))
        return false
      end
    end
  else -- credentials == "bot-account"
    assert(credentials == "bot-account")
    arguments = {
      format = "json",
      action = "login",
      lgname = username,
      lgpassword = password,
      lgtoken = logintoken
    }
    jsonres = MediaWikiApi.performRequest(arguments)
    local loginResult = jsonres.login.result
    if loginResult == "Success" then
      return true
    else
      MediaWikiApi.trace('Login failed: ' .. (jsonres.login.reason or "Unknown reason"))
      return false
    end
  end
end
-- end of LrMediaWiki code

return MediaWikiApi
