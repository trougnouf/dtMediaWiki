--[[
Author: Trougnouf (Benoit Brummer) <trougnouf@gmail.com>

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

package.path = package.path..';/dtMediaWiki/?.lua'
package.path = package.path..';/usr/share/darktable/lua/contrib/dtMediaWiki/?.lua'
--TODO local these
https = require("ssl.https")
json = require('json')
ltn12 = require "ltn12"
mpost = require "multipart-post"

MediaWikiApi = {
    userAgent = string.format('mediawikilua %d.%d', 0,1),
    apiPath = "https://commons.wikimedia.org/w/api.php",
    cookie = {},
    edit_token = nil
}

function httpsget(url, reqheaders)
    local res, code, resheaders, status = https.request {
        url = url,
        headers = reqheaders
    }
    resheaders.status = code

    return res, respheaders
end

function httpspost(url, postBody, reqheaders)
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

-- parse a received cookie and update MediaWikiApi.cookie
function MediaWikiApi.parseCookie(unparsedcookie)
  while unparsedcookie and string.len(unparsedcookie) > 0 do
    local i = string.find(unparsedcookie,";")
    local crumb = string.sub(unparsedcookie,1,i-1)
    local isep = string.find(crumb,"=")
    if isep then
      local cvar = string.sub(crumb, 1, isep-1)
      local icvarcomma = string.find(cvar, ",")
      while icvarcomma do
        cvar = string.sub(cvar, icvarcomma+2)
        icvarcomma = string.find(cvar, ",")
      end
      
      MediaWikiApi.cookie[cvar] = string.sub(crumb, isep+1)
    end
    local nexti = string.find(unparsedcookie,",")
    if not nexti then return end
    unparsedcookie = string.sub(unparsedcookie, nexti+2)
  end
end

-- generate a cookie string from MediaWikiApi.cookie to send to server
function MediaWikiApi.cookie2string()
  prestr = {}
  cstr = ""
  for cvar,cval in pairs(MediaWikiApi.cookie) do
      table.insert(prestr,cvar.."="..cval..";")
  end
  return table.concat(prestr)
end

-- Demand an edit token. probably can change this to request only one per session
function MediaWikiApi.getEditToken()
  --if MediaWikiApi.edit_token == nil then
    local arguments = {
      action = 'query',
      meta = 'tokens',
      type = 'csrf',
      format = 'json',
    }
    local jsonres = MediaWikiApi.performRequest(arguments)
    MediaWikiApi.edit_token = jsonres.query.tokens.csrftoken
  --end
  return MediaWikiApi.edit_token
end


function MediaWikiApi.uploadfile(filepath, pagetext, filename, overwrite)
  file_handler = io.open(filepath)
  content = {
    action = 'upload',
    filename = filename,
    text = pagetext,
    comment = 'Uploaded with dtMediaWiki',
    token = MediaWikiApi.getEditToken(),
    file = {
        filename = "whatevs",
        data = file_handler:read("*all"),
    },
  }
  if overwrite then content["ignorewarnings"] = 'true' end
  res = {}
  req = mpost.gen_request(content)
  req.headers["cookie"] = MediaWikiApi.cookie2string()
  req.url = MediaWikiApi.apiPath
  req.sink = ltn12.sink.table(res)
  _,code,resheaders = https.request(req)
  print(resheaders) -- debug
  MediaWikiApi.parseCookie(resheaders["set-cookie"])
  return code,resheaders, res
end



-- Code adapted from LrMediaWiki:
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
    requestHeaders["Cookie"] = MediaWikiApi.cookie2string()
    MediaWikiUtils.trace('Performing HTTP request');
    MediaWikiUtils.trace('Path:')
    MediaWikiUtils.trace(path)
    MediaWikiUtils.trace('Request body:');
    MediaWikiUtils.trace(requestBody);
    MediaWikiUtils.trace('Request header: ')

    local resultBody, resultHeaders
    if post then
        resultBody, resultHeaders = httpspost(path, requestBody, requestHeaders)
    else
        resultBody, resultHeaders = httpsget(path .. '?' .. requestBody, requestHeaders)
    end

    MediaWikiUtils.trace('Result status:');
    MediaWikiUtils.trace(resultHeaders.status);

    if not resultHeaders.status then
        throwUserError(LOC("$$$/LrMediaWiki/Api/NoConnection=No network connection."))
    elseif resultHeaders.status ~= 200 then
        MediaWikiApi.httpError(resultHeaders.status)
    end
    MediaWikiApi.parseCookie(resultHeaders["set-cookie"])
    --print("new cookie: "..resultHeaders["set-cookie"])
    MediaWikiUtils.trace('Result body:');
    MediaWikiUtils.trace(resultBody);
    MediaWikiUtils.trace('Result headers:')
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
-- end of LrMediaWiki code
