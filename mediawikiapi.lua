--[[dtMediaWiki is a fork of LrMediaWiki for darktable
    Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>

LrMediaWiki authors:
Robin Krahl <robin.krahl@wikipedia.de>
Eckhard Henkel <eckhard.henkel@wikipedia.de>

Dependencies:
* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-multipart-post: HTTP Multipart Post helper for lua
* lua-luajson: JSON parser/encoder for Lua
:(darktable is not a dependency)
]]

--TODO local these
https = require("ssl.https")
json = require('json')
ltn12 = require "ltn12"
mpost = require "multipart-post"

prpr = require('pl.pretty').dump --dbg pretty printer

dtHttp = {}
function dtHttp.get(url, reqheaders)
    local res, code, resheaders, status = https.request {
        url = url,
        headers = reqheaders
    }
    resheaders.status = code

    return res, respheaders
end
function dtHttp.post(url, postBody, reqheaders)
    local res = {}
    _,code,resheaders,status = https.request{
        url = url,
        method="POST",
        headers=reqheaders,
        source=ltn12.source.string(postBody),
        sink=ltn12.sink.table(res),
    }
    resheaders.status = code

    return table.concat(res), resheaders
end

function throwUserError(text)
    print(text)
end


-- forked stuff
Info = {
    VERSION = {
        major = 0,
        minor = 1
    }
}

MediaWikiApi = {
    userAgent = string.format('mediawikilua %d.%d', Info.VERSION.major, Info.VERSION.minor),
    apiPath = "https://commons.wikimedia.org/w/api.php",
    cookie = nil,
    edit_token = nil
}

MediaWikiUtils = {}

MediaWikiUtils.trace = function(message)
    print(message)
end

--- URL-encode a string according to RFC 3986.
-- Based on http://lua-users.org/wiki/StringRecipes
-- @param str the string to encode
-- @return the URL-encoded string
function MediaWikiApi.urlEncode(str)
    if str then
        str = string.gsub(str, '\n', '\r\n')
        str = string.gsub (str, '([^%w %-%_%.%~])',
                function(c) return string.format('%%%02X', string.byte(c)) end)
        str = string.gsub(str, ' ', '+')
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
            body = body .. '&'
        else
            body = ''
        end
        body = body .. MediaWikiApi.urlEncode(key) .. '=' .. MediaWikiApi.urlEncode(value)
    end
    return body or ''
end

function MediaWikiApi.performHttpRequest(path, arguments, post) -- changed signature!
    local requestBody = MediaWikiApi.createRequestBody(arguments)
    local requestHeaders = {
        ["Content-Type"] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = MediaWikiApi.userAgent,
    }
    if post then
        requestHeaders["Content-Length"] = #requestBody
    end
    if(MediaWikiApi.cookie ~= nil) then requestHeaders["cookie"] = MediaWikiApi.cookie end
    MediaWikiUtils.trace('Performing HTTP request');
    MediaWikiUtils.trace('Path:')
    MediaWikiUtils.trace(path)
    MediaWikiUtils.trace('Request body:');
    MediaWikiUtils.trace(requestBody);

    local resultBody, resultHeaders
    if post then
        resultBody, resultHeaders = dtHttp.post(path, requestBody, requestHeaders)
    else
        resultBody, resultHeaders = dtHttp.get(path .. '?' .. requestBody, requestHeaders)
    end

    MediaWikiUtils.trace('Result status:');
    MediaWikiUtils.trace(resultHeaders.status);

    if not resultHeaders.status then
        throwUserError(LOC("$$$/LrMediaWiki/Api/NoConnection=No network connection."))
    elseif resultHeaders.status ~= 200 then
        MediaWikiApi.httpError(resultHeaders.status)
    end
    MediaWikiApi.cookie = resultHeaders["set-cookie"]
    print("new cookie: "..MediaWikiApi.cookie)
    MediaWikiUtils.trace('Result body:');
    MediaWikiUtils.trace(resultBody);

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
        action = 'logout',
    }
    MediaWikiApi.performRequest(arguments)
end

function MediaWikiApi.login(username, password)
    -- See https://www.mediawiki.org/wiki/API:Login
    -- Check if the credentials are a main-account or a bot-account.
    -- The different credentials need different login arguments.
    -- The existance of the character "@" inside of an username is an
    -- identicator if the credentials are a bot-account or a main-account.
    local credentials
    if string.find(username, '@') then
        credentials = 'bot-account'
    else
        credentials = 'main-account'
    end
    local msg = 'Credentials: ' .. credentials
    MediaWikiUtils.trace(msg)

    -- Check if a user is logged in:
    local arguments = {
        action = 'query',
        meta = 'userinfo',
        format = 'json',
    }
    local jsonres = MediaWikiApi.performRequest(arguments)
    local id = jsonres.query.userinfo.id
    local name = jsonres.query.userinfo.name
    if id == '0' or id == 0 then -- not logged in, name is the IP address
        MediaWikiUtils.trace('Not logged in, need to login')
    else -- id ~= '0' – logged in
        msg = 'Logged in as user \"' .. name .. '\" (ID: ' .. id .. ')'
        MediaWikiUtils.trace(msg)
        if name == username then -- user is already logged in
            MediaWikiUtils.trace('No new login needed (1)')
            return true
        else -- name ~= username
            -- Check if name is main-account name of bot-username
            if credentials == 'bot-account' then
                local pattern = '(.*)@' -- all characters up to "@"
                if name == string.match(username, pattern) then
                    MediaWikiUtils.trace('No new login needed (2)')
                    return true
                end
            end
            msg = 'Logout and new login needed with username \"' .. username .. '\".'
            MediaWikiUtils.trace(msg)
            MediaWikiApi.logout() -- without this logout a new login MIGHT fail
        end
    end

    -- A login token needs to be retrieved prior of a login action:
    arguments = {
        action = 'query',
        meta = 'tokens',
        type = 'login',
        format = 'json',
    }
    jsonres = MediaWikiApi.performRequest(arguments)
    local logintoken = jsonres.query.tokens.logintoken

    -- Perform login:
    if credentials == 'main-account' then
        arguments = {
            format = 'json',
            action = 'clientlogin',
            loginreturnurl = 'https://www.mediawiki.org', -- dummy; required parameter
            username = username,
            password = password,
            logintoken = logintoken,
        }
        jsonres = MediaWikiApi.performRequest(arguments)
        local loginResult = jsonres.clientlogin.status
        if loginResult == 'PASS' then
            return true
        else
            return jsonres.clientlogin.message
        end
    else -- credentials == bot-account
        assert(credentials == 'bot-account')
        arguments = {
            format = 'json',
            action = 'login',
            lgname = username,
            lgpassword = password,
            lgtoken = logintoken,
        }
        jsonres = MediaWikiApi.performRequest(arguments)
        local loginResult = jsonres.login.result
        if loginResult == 'Success' then
            return true
        else
            return jsonres.login.reason
        end
    end
end
-- end of forked stuff


function MediaWikiApi.getEditToken()
  if MediaWikiApi.edit_token == nil then
    local arguments = {
      action = 'query',
      meta = 'tokens',
      type = 'csrf',
      format = 'json',
    }
    local jsonres = MediaWikiApi.performRequest(arguments)
    MediaWikiApi.edit_token = jsonres.query.tokens.csrftoken
  end
  return MediaWikiApi.edit_token
end


function MediaWikiApi.uploadfile(filepath, pagetext)
  file_handler = io.open(filepath)
  content = {
    action = 'upload',
    filename = "trougnoufsandbox.png",
    text = pagetext,
    file = file_handler:read("*all"),
    token = MediaWikiApi.getEditToken(),
  }
  res = {}
  req = mpost.gen_request(content)
  req.headers["cookie"] = MediaWikiApi.cookie
  req.url = MediaWikiApi.apiPath
  req.sink = ltn12.sink.table(res)
  prpr(req)
  _,code,resheaders = https.request(req)
  return code,resheaders, res
end

-- for testing (send to localhost to get raw request)
function MediaWikiApi.publicuploadfile(filepath, pagetext, rurl, usehttps)
  file_handler = io.open(filepath)
  content = {
    action = 'upload',
    filename = "trougnoufsandbox.png",
    text = pagetext,
    token = MediaWikiApi.getEditToken(),
    file = {filename = "trougnoufsandbox.png", data = file_handler:read("*all")},
  }
  res = {}
  req = mpost.gen_request(content)
  req.headers["cookie"] = "MediaWikiApi.cookie"
  req.url = rurl
  req.sink = ltn12.sink.table(res)
  prpr(req)
  if(usehttps) then
    _,code,resheaders = https.request(req)
  else
    _,code,resheaders = require("socket.http").request(req)
  end
  
  return code,resheaders, res
end

--function dtHttp.post(url, postBody, reqheaders)
--    local res = {}
--    _,code,resheaders,status = https.request{
--        url = url,
--        method="POST",
--        headers=reqheaders,
--        source=ltn12.source.string(postBody),
--        sink=ltn12.sink.table(res),
--    }
--    resheaders.status = code

--    return table.concat(res), resheaders
--end



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

