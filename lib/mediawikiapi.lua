--[[
  dtMediaWiki MediaWiki API backend

  Uses curl for HTTP(S), session handling, and multipart uploads.
  This avoids the lua-sec, lua-socket/ltn12, lua-luajson, and
  lua-multipart-post dependencies used by the previous backend.

  Requires:
    curl
    dkjson.lua
]]

local json = require "contrib/dtMediaWiki/lib/dkjson"

local MediaWikiApi = {
  userAgent = "dtMediaWiki-curl",
  apiPath = "https://commons.wikimedia.org/w/api.php",
  edit_token = nil,

  -- nil: curl/curl.exe is resolved through PATH
  curl_path = nil
}

-----------------------------------------------------------------------
-- Platform / paths
-----------------------------------------------------------------------

local is_windows =
  package.config:sub(1, 1) == "\\"

local temp_dir

if is_windows then
  temp_dir =
    os.getenv("TEMP")
    or os.getenv("TMP")
    or "."
else
  temp_dir =
    os.getenv("TMPDIR")
    or "/tmp"

  -- /tmp is shared among users: create a private directory (0700)
  -- so that cookies and request files cannot be read or replaced
  -- through predictable names or symlinks.
  local p = io.popen(
    "mktemp -d '" ..
    temp_dir:gsub("'", "'\\''") ..
    "/dtmediawiki.XXXXXXXX' 2>/dev/null"
  )

  local private_dir = p and p:read("*l")

  if p then
    p:close()
  end

  if private_dir and private_dir ~= "" then
    temp_dir = private_dir
  else
    print("dtMediaWiki: mktemp -d failed, using " .. temp_dir)
  end
end

-- curl understands forward slashes on Windows and this avoids
-- backslash escaping inside curl configuration files.
if is_windows then
  temp_dir = temp_dir:gsub("\\", "/")
end

math.randomseed(os.time())

local session_id =
  tostring(os.time()) ..
  "-" ..
  tostring(math.random(100000, 999999))

local function temp_file(name)
  return temp_dir ..
         "/dtmediawiki-" ..
         session_id ..
         "-" ..
         name
end

MediaWikiApi.temp_file = temp_file

local cookie_file =
  temp_file("cookies.txt")

local debug_file =
  temp_file("debug.txt")

local request_counter = 0

-----------------------------------------------------------------------
-- Debug logging
-----------------------------------------------------------------------

local function log(...)
  local f = io.open(debug_file, "a")

  if not f then
    return
  end

  local args = {...}

  for i, value in ipairs(args) do
    f:write(tostring(value))

    if i < #args then
      f:write(" ")
    end
  end

  f:write("\n")
  f:close()
end

do
  local f = io.open(debug_file, "w")

  if f then
    f:write("dtMediaWiki curl backend\n")
    f:write("Lua: " .. tostring(_VERSION) .. "\n")
    f:write(
      "platform: " ..
      (is_windows and "Windows" or "Unix") ..
      "\n"
    )
    f:write("session: " .. session_id .. "\n")
    f:close()
  end
end

local function throwUserError(text)
  log("ERROR:", tostring(text))
  print(tostring(text))
end

-----------------------------------------------------------------------
-- File helpers
-----------------------------------------------------------------------

local function read_file(filename)

  local f, err =
    io.open(filename, "rb")

  if not f then
    return nil, err
  end

  local content =
    f:read("*all")

  f:close()

  return content
end

local function remove_file(filename)

  if filename then
    pcall(os.remove, filename)
  end
end

-----------------------------------------------------------------------
-- curl configuration quoting
-----------------------------------------------------------------------

local function curl_escape(value)

  value = tostring(value)

  value = value:gsub("\\", "\\\\")
  value = value:gsub('"', '\\"')
  value = value:gsub("\r", "\\r")
  value = value:gsub("\n", "\\n")
  value = value:gsub("\t", "\\t")

  return value
end

local function cfg_line(name, value)

  return name ..
         ' = "' ..
         curl_escape(value) ..
         '"\n'
end

-----------------------------------------------------------------------
-- Shell quoting
-----------------------------------------------------------------------

local function shell_quote(value)

  value = tostring(value)

  if is_windows then
    return '"' ..
           value:gsub('"', '""') ..
           '"'
  end

  return "'" ..
         value:gsub("'", "'\\''") ..
         "'"
end

local function get_curl()

  if MediaWikiApi.curl_path
      and MediaWikiApi.curl_path ~= "" then

    return MediaWikiApi.curl_path
  end

  return is_windows
         and "curl.exe"
         or "curl"
end

-----------------------------------------------------------------------
-- Sensitive argument detection
-----------------------------------------------------------------------

local sensitive_fields = {
  password   = true,
  lgpassword = true,
  token      = true,
  logintoken = true,
  lgtoken    = true
}

local function safe_argument_description(arguments)

  local result = {}

  for key, value in pairs(arguments) do

    if sensitive_fields[key] then

      table.insert(
        result,
        tostring(key) .. "=***"
      )

    else

      table.insert(
        result,
        tostring(key) ..
        "=" ..
        tostring(value)
      )

    end
  end

  table.sort(result)

  return table.concat(result, " ")
end

-----------------------------------------------------------------------
-- HTTP request
-----------------------------------------------------------------------

local function curl_request(arguments)

  request_counter =
    request_counter + 1

  local request_id =
    tostring(request_counter)

  local config_file =
    temp_file(
      request_id .. "-request.cfg"
    )

  local response_file =
    temp_file(
      request_id .. "-response.json"
    )

  local stderr_file =
    temp_file(
      request_id .. "-stderr.txt"
    )

  local status_file =
    temp_file(
      request_id .. "-status.txt"
    )

  -------------------------------------------------------------
  -- curl configuration
  -------------------------------------------------------------

  local cfg = {}

  table.insert(cfg, "silent\n")
  table.insert(cfg, "show-error\n")
  table.insert(cfg, "location\n")
  -- HTTP status goes to stdout, see status_file. Checked manually
  -- because fail-with-body needs curl >= 7.76.
  table.insert(cfg, 'write-out = "%{http_code}"\n')

  table.insert(
    cfg,
    cfg_line(
      "user-agent",
      MediaWikiApi.userAgent
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "url",
      MediaWikiApi.apiPath
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "request",
      "POST"
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "output",
      response_file
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "cookie",
      cookie_file
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "cookie-jar",
      cookie_file
    )
  )

  -------------------------------------------------------------
  -- POST parameters
  -------------------------------------------------------------

  for key, value in pairs(arguments) do

    table.insert(
      cfg,
      cfg_line(
        "data-urlencode",
        tostring(key) ..
        "=" ..
        tostring(value)
      )
    )
  end

  -------------------------------------------------------------
  -- Write temporary curl config
  -------------------------------------------------------------

  local f, err =
    io.open(config_file, "wb")

  if not f then

    throwUserError(
      "Unable to create curl configuration: " ..
      tostring(err)
    )

    return nil
  end

  f:write(table.concat(cfg))
  f:close()

  -------------------------------------------------------------
  -- Debug metadata
  --
  -- Never log config contents.
  -------------------------------------------------------------

  log("")
  log(
    "---- request",
    request_id,
    "----"
  )

  log(
    "arguments:",
    safe_argument_description(arguments)
  )

  -------------------------------------------------------------
  -- Execute curl
  -------------------------------------------------------------

  local command =
    get_curl() ..
    " --config " ..
    shell_quote(config_file) ..
    " > " ..
    shell_quote(status_file) ..
    " 2> " ..
    shell_quote(stderr_file)

  local ok, why, code =
    os.execute(command)

  log(
    "curl:",
    "ok=" .. tostring(ok),
    "why=" .. tostring(why),
    "code=" .. tostring(code)
  )

  -------------------------------------------------------------
  -- Collect response
  -------------------------------------------------------------

  local stderr =
    read_file(stderr_file)

  if stderr
      and stderr ~= "" then

    log(
      "curl stderr:",
      stderr
    )
  end

  local body, body_error =
    read_file(response_file)

  if body then

    log(
      "response bytes:",
      tostring(#body)
    )

  else

    log(
      "response unavailable:",
      tostring(body_error)
    )
  end

  -------------------------------------------------------------
  -- IMPORTANT:
  -- Remove config immediately. It may contain credentials.
  -------------------------------------------------------------

  local status =
    tonumber(read_file(status_file) or "")

  remove_file(config_file)
  remove_file(response_file)
  remove_file(stderr_file)
  remove_file(status_file)

  if not ok then

    throwUserError(
      "curl request failed (" ..
      tostring(why) ..
      "/" ..
      tostring(code) ..
      ")"
    )

    return nil
  end

  if status and status >= 400 then

    throwUserError(
      "HTTP error " ..
      tostring(status)
    )

    return nil
  end

  return body
end

-----------------------------------------------------------------------
-- JSON
-----------------------------------------------------------------------

local function decode_json(body)

  if not body then
    return nil
  end

  -- TODO position is unused
  local result, position, err = -- luacheck: ignore
    json.decode(body, 1, nil)

  if err then

    throwUserError(
      "JSON decode error: " ..
      tostring(err)
    )

    return nil
  end

  return result
end

-----------------------------------------------------------------------
-- Generic MediaWiki request
-----------------------------------------------------------------------

function MediaWikiApi.performRequest(arguments)

  if arguments.format == nil then
    arguments.format = "json"
  end

  local body =
    curl_request(arguments)

  if not body then
    return nil
  end

  local result =
    decode_json(body)

  if not result then
    return nil
  end

  if result.error then

    throwUserError(
      "MediaWiki API error " ..
      tostring(result.error.code) ..
      ": " ..
      tostring(result.error.info)
    )
  end

  return result
end

-----------------------------------------------------------------------
-- User info
-----------------------------------------------------------------------

function MediaWikiApi.getUserInfo()

  local result =
    MediaWikiApi.performRequest {
      action = "query",
      meta   = "userinfo",
      format = "json"
    }

  if result
      and result.query
      and result.query.userinfo then

    return result.query.userinfo
  end

  return nil
end

-----------------------------------------------------------------------
-- Category search
-----------------------------------------------------------------------

-- Returns category names without the "Category:" prefix.
function MediaWikiApi.searchCategories(term, limit)

  local result =
    MediaWikiApi.performRequest {
      action      = "query",
      list        = "search",
      srsearch    = term,
      srnamespace = "14",
      srlimit     = tostring(limit or 10),
      srprop      = ""
    }

  local categories = {}

  if result
      and result.query
      and result.query.search then

    for _, item in ipairs(result.query.search) do

      local title =
        tostring(item.title or "")
          :gsub("^Category:", "")

      if title ~= "" then
        table.insert(categories, title)
      end
    end
  end

  return categories
end

-----------------------------------------------------------------------
-- Login token
-----------------------------------------------------------------------

function MediaWikiApi.getLoginToken()

  local result =
    MediaWikiApi.performRequest {
      action = "query",
      meta   = "tokens",
      type   = "login",
      format = "json"
    }

  if result
      and result.query
      and result.query.tokens then

    local token =
      result.query.tokens.logintoken

    if token then
      log("login token: received")
      return token
    end
  end

  throwUserError(
    "Unable to retrieve login token"
  )

  return nil
end

-----------------------------------------------------------------------
-- Edit/CSRF token
-----------------------------------------------------------------------

function MediaWikiApi.getEditToken()

  local result =
    MediaWikiApi.performRequest {
      action = "query",
      meta   = "tokens",
      type   = "csrf",
      format = "json"
    }

  if result
      and result.query
      and result.query.tokens then

    MediaWikiApi.edit_token =
      result.query.tokens.csrftoken
  end

  if MediaWikiApi.edit_token then
    log("CSRF token: received")
  else
    throwUserError(
      "Unable to retrieve CSRF token"
    )
  end

  return MediaWikiApi.edit_token
end

-----------------------------------------------------------------------
-- Multipart upload
--
-- Drop-in replacement for upstream uploadfile().
--
-- Unlike the original implementation, the exported image is NOT read
-- completely into Lua memory. curl streams it directly from disk.
-----------------------------------------------------------------------

function MediaWikiApi.uploadfile(
    filepath,
    pagetext,
    filename,
    overwrite,
    comment
)

  log("")
  log("---- upload ----")
  log("source file:", tostring(filepath))
  log("target filename:", tostring(filename))

  ---------------------------------------------------------------------
  -- Match upstream filename sanitizing.
  ---------------------------------------------------------------------

  local filename_replaced =
    tostring(filename)
      :gsub("'", "")
      :gsub('"', "")

  ---------------------------------------------------------------------
  -- Obtain CSRF token using our authenticated cookie session.
  ---------------------------------------------------------------------

  local token =
    MediaWikiApi.getEditToken()

  if not token then
    throwUserError(
      "Unable to upload: no CSRF token"
    )

    return false
  end

  ---------------------------------------------------------------------
  -- Check exported file before invoking curl.
  ---------------------------------------------------------------------

  local image =
    io.open(filepath, "rb")

  if not image then
    throwUserError(
      "Unable to open exported file: " ..
      tostring(filepath)
    )

    return false
  end

  local filesize =
    image:seek("end")

  image:close()

  log(
    "source size:",
    tostring(filesize or "unknown"),
    "bytes"
  )

  ---------------------------------------------------------------------
  -- Temporary files
  ---------------------------------------------------------------------

  request_counter =
    request_counter + 1

  local request_id =
    tostring(request_counter)

  local config_file =
    temp_file(
      request_id .. "-upload.cfg"
    )

  local response_file =
    temp_file(
      request_id .. "-upload-response.json"
    )

  local stderr_file =
    temp_file(
      request_id .. "-upload-stderr.txt"
    )

  local status_file =
    temp_file(
      request_id .. "-upload-status.txt"
    )

  ---------------------------------------------------------------------
  -- Build curl configuration.
  --
  -- form / form-string correspond to curl -F / --form-string.
  --
  -- The file field deliberately uses form rather than form-string:
  -- @ tells curl to stream the file from disk.
  ---------------------------------------------------------------------

  local cfg = {}

  table.insert(cfg, "silent\n")
  table.insert(cfg, "show-error\n")
  table.insert(cfg, "location\n")
  -- HTTP status goes to stdout, see status_file. Checked manually
  -- because fail-with-body needs curl >= 7.76.
  table.insert(cfg, 'write-out = "%{http_code}"\n')

  table.insert(
    cfg,
    cfg_line(
      "user-agent",
      MediaWikiApi.userAgent
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "url",
      MediaWikiApi.apiPath
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "output",
      response_file
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "cookie",
      cookie_file
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "cookie-jar",
      cookie_file
    )
  )

  ---------------------------------------------------------------------
  -- Ordinary multipart fields
  ---------------------------------------------------------------------

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "action=upload"
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "format=json"
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "filename=" .. filename_replaced
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "text=" .. tostring(pagetext or "")
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "comment=" .. tostring(comment or "")
    )
  )

  table.insert(
    cfg,
    cfg_line(
      "form-string",
      "token=" .. token
    )
  )

  if overwrite then

    table.insert(
      cfg,
      cfg_line(
        "form-string",
        "ignorewarnings=true"
      )
    )

  end

  ---------------------------------------------------------------------
  -- File field
  --
  -- curl config parser treats backslashes specially, therefore use /
  -- for the path on Windows.
  ---------------------------------------------------------------------

  local curl_filepath =
    tostring(filepath)

  if is_windows then
    curl_filepath =
      curl_filepath:gsub("\\", "/")
  end

  -- Double-quote path and filename, otherwise curl cuts them at
  -- "," or ";". Inside quotes, curl unescapes \\ and \".
  local function form_quote(value)
    return '"' ..
           value:gsub("\\", "\\\\")
                :gsub('"', '\\"') ..
           '"'
  end

  local form_file =
    "file=@" ..
    form_quote(curl_filepath) ..
    ";filename=" ..
    form_quote(filename_replaced)

  table.insert(
    cfg,
    cfg_line(
      "form",
      form_file
    )
  )

  ---------------------------------------------------------------------
  -- Write temporary curl configuration.
  --
  -- IMPORTANT: this contains the CSRF token and page text.
  ---------------------------------------------------------------------

  local f, err =
    io.open(config_file, "wb")

  if not f then

    throwUserError(
      "Unable to create upload configuration: " ..
      tostring(err)
    )

    return false
  end

  f:write(table.concat(cfg))
  f:close()

  ---------------------------------------------------------------------
  -- Execute curl
  ---------------------------------------------------------------------

  log(
    "upload request:",
    request_id
  )

  log(
    "overwrite:",
    tostring(overwrite)
  )

  -- Deliberately do NOT log cfg or the command contents beyond this.
  -- cfg contains the CSRF token and Commons wikitext.

  local command =
    get_curl() ..
    " --config " ..
    shell_quote(config_file) ..
    " > " ..
    shell_quote(status_file) ..
    " 2> " ..
    shell_quote(stderr_file)

  local ok, why, code =
    os.execute(command)

  log(
    "upload curl:",
    "ok=" .. tostring(ok),
    "why=" .. tostring(why),
    "code=" .. tostring(code)
  )

  ---------------------------------------------------------------------
  -- Read results
  ---------------------------------------------------------------------

  local stderr =
    read_file(stderr_file)

  if stderr and stderr ~= "" then
    log(
      "upload curl stderr:",
      stderr
    )
  end

  local body, body_error =
    read_file(response_file)

  if body then

    log(
      "upload response bytes:",
      tostring(#body)
    )

  else

    log(
      "upload response unavailable:",
      tostring(body_error)
    )
  end

  ---------------------------------------------------------------------
  -- Remove sensitive/request-specific files immediately.
  ---------------------------------------------------------------------

  local status =
    tonumber(read_file(status_file) or "")

  remove_file(config_file)
  remove_file(response_file)
  remove_file(stderr_file)
  remove_file(status_file)

  if not ok then

    throwUserError(
      "curl upload failed (" ..
      tostring(why) ..
      "/" ..
      tostring(code) ..
      ")"
    )

    return false
  end

  if status and status >= 400 then

    throwUserError(
      "HTTP error " ..
      tostring(status)
    )

    return false
  end

  if not body then

    throwUserError(
      "No response received from Commons upload API"
    )

    return false
  end

  ---------------------------------------------------------------------
  -- Parse MediaWiki response
  ---------------------------------------------------------------------

  local result =
    decode_json(body)

  if not result then

    throwUserError(
      "Unable to decode Commons upload response"
    )

    return false
  end

  if result.error then

    throwUserError(
      "Commons upload API error " ..
      tostring(result.error.code) ..
      ": " ..
      tostring(result.error.info)
    )

    return false
  end

  if not result.upload then

    throwUserError(
      "Unexpected Commons upload response"
    )

    return false
  end

  log(
    "upload result:",
    tostring(result.upload.result)
  )

  ---------------------------------------------------------------------
  -- Success
  ---------------------------------------------------------------------

  if result.upload.result == "Success" then

    log(
      "upload successful:",
      filename_replaced
    )

    return true
  end

  ---------------------------------------------------------------------
  -- Warnings
  --
  -- Without ignorewarnings MediaWiki can return result="Warning".
  -- Keep the complete warning structure out of the log for now, but
  -- record the warning keys.
  ---------------------------------------------------------------------

  if result.upload.result == "Warning" then

    log("upload warning received")

    if result.upload.warnings then

      for warning, _ in pairs(
          result.upload.warnings
      ) do

        log(
          "upload warning:",
          tostring(warning)
        )

      end
    end

    return false
  end

  throwUserError(
    "Commons upload returned result: " ..
    tostring(result.upload.result)
  )

  return false
end

-----------------------------------------------------------------------
-- EmailAuth / interactive continuation
--
-- When the server requests an email verification code, the login
-- cannot be completed on the spot: there is no terminal to read
-- the code from. The login is then parked in a "pending" state
-- until the user enters the code in the metadata panel, which
-- finishes it by calling complete2FA().
-----------------------------------------------------------------------

local authenticated = false

local pending_2fa = nil

function MediaWikiApi.isAuthenticated()
  return authenticated
end

function MediaWikiApi.is2FAPending()
  return pending_2fa ~= nil
end

function MediaWikiApi.get2FAPromptMessage()
  return pending_2fa and pending_2fa.message or ""
end

function MediaWikiApi.complete2FA(code)

  if not pending_2fa then
    return false
  end

  code =
    tostring(code or "")
      :gsub("^%s+", "")
      :gsub("%s+$", "")

  if code == "" then

    throwUserError(
      "Authentication cancelled"
    )

    return false
  end

  local result =
    MediaWikiApi.performRequest {
      action        = "clientlogin",
      format        = "json",
      logincontinue = "1",
      logintoken    = pending_2fa.login_token,
      token         = code
    }

  if not result
      or not result.clientlogin then

    pending_2fa = nil

    throwUserError(
      "Unexpected clientlogin response"
    )

    return false
  end

  local status =
    result.clientlogin.status

  log(
    "clientlogin status:",
    tostring(status)
  )

  ---------------------------------------------------------
  -- Success
  ---------------------------------------------------------

  if status == "PASS" then

    pending_2fa = nil

    authenticated = true

    local authenticated_user =
      MediaWikiApi.getUserInfo()

    if authenticated_user then

      log(
        "login successful:",
        tostring(authenticated_user.name),
        "id:",
        tostring(authenticated_user.id)
      )

    else

      log(
        "login successful; userinfo unavailable"
      )
    end

    return true

  ---------------------------------------------------------
  -- Interactive authentication (wrong code)
  ---------------------------------------------------------

  elseif status == "UI" then

    local requests =
      result.clientlogin.requests

    local auth_request =
      requests
      and requests[1]

    if auth_request
        and auth_request.id ==
          "MediaWiki\\Extension\\EmailAuth\\EmailAuthAuthenticationRequest"
    then

      pending_2fa.message =
        result.clientlogin.message
        or "Verification code rejected, please try again"

      log(
        "verification code rejected, waiting for a new code"
      )

      return false
    end

    pending_2fa = nil

    throwUserError(
      "Unsupported Wikimedia authentication step"
    )

    return false

  ---------------------------------------------------------
  -- Other failure/status
  ---------------------------------------------------------

  else

    pending_2fa = nil

    throwUserError(
      "Wikimedia login failed: " ..
      tostring(
        result.clientlogin.message
        or status
        or "unknown reason"
      )
    )

    return false
  end
end

-----------------------------------------------------------------------
-- Logout
-----------------------------------------------------------------------

function MediaWikiApi.logout()

  MediaWikiApi.performRequest {
    action = "logout",
    format = "json"
  }

  MediaWikiApi.edit_token = nil

  authenticated = false

  pending_2fa = nil

  log("logout complete")
end

-----------------------------------------------------------------------
-- Login
--
-- Authentication behavior intentionally follows upstream dtMediaWiki:
--
--   normal account -> clientlogin
--   name@bot       -> action=login
-----------------------------------------------------------------------

function MediaWikiApi.login(username, password)

  local credentials =
    string.find(username, "@")
    and "bot-account"
    or "main-account"

  log(
    "credentials:",
    credentials
  )

  -------------------------------------------------------------
  -- Already logged in?
  -------------------------------------------------------------

  local user =
    MediaWikiApi.getUserInfo()

  if user
      and user.id
      and user.id ~= 0
      and user.id ~= "0" then

    log(
      "already authenticated as:",
      tostring(user.name),
      "id:",
      tostring(user.id)
    )

    local expected_name =
      username

    if credentials == "bot-account" then
      expected_name =
        string.match(
          username,
          "(.*)@"
        )
    end

    if user.name == expected_name then

      log(
        "existing session can be reused"
      )

      authenticated = true

      return true
    end

    log(
      "different user authenticated; logging out"
    )

    MediaWikiApi.logout()
  end

  -------------------------------------------------------------
  -- Login token
  -------------------------------------------------------------

  local login_token =
    MediaWikiApi.getLoginToken()

  if not login_token then
    return false
  end

  -------------------------------------------------------------
  -- Normal Wikimedia account
  -------------------------------------------------------------

  if credentials == "main-account" then

    local arguments = {
      action         = "clientlogin",
      format         = "json",
      loginreturnurl =
        "https://www.mediawiki.org",
      username       = username,
      password       = password,
      logintoken     = login_token
    }

    -- Single pass: any interactive step parks the login as
    -- "pending" (see complete2FA), so the request is never
    -- repeated here.
    do

      local result =
        MediaWikiApi.performRequest(
          arguments
        )

      if not result
          or not result.clientlogin then

        throwUserError(
          "Unexpected clientlogin response"
        )

        return false
      end

      local status =
        result.clientlogin.status

      log(
        "clientlogin status:",
        tostring(status)
      )

      ---------------------------------------------------------
      -- Success
      ---------------------------------------------------------

      if status == "PASS" then

        authenticated = true

        local authenticated_user =
          MediaWikiApi.getUserInfo()

        if authenticated_user then

          log(
            "login successful:",
            tostring(authenticated_user.name),
            "id:",
            tostring(authenticated_user.id)
          )

        else

          log(
            "login successful; userinfo unavailable"
          )
        end

        return true

      ---------------------------------------------------------
      -- Interactive authentication
      ---------------------------------------------------------

      elseif status == "UI" then

        local requests =
          result.clientlogin.requests

        local auth_request =
          requests
          and requests[1]

        if auth_request
            and auth_request.id ==
              "MediaWiki\\Extension\\EmailAuth\\EmailAuthAuthenticationRequest"
        then

          -- A verification code is required. There is no terminal
          -- to read it from, so park the login until the user
          -- enters the code in the metadata panel (complete2FA).
          pending_2fa = {
            login_token = login_token,
            message     = result.clientlogin.message or ""
          }

          log(
            "verification code required; waiting for input in the metadata panel"
          )

          return "pending"

        else

          throwUserError(
            "Unsupported Wikimedia authentication step"
          )

          return false
        end

      ---------------------------------------------------------
      -- Other failure/status
      ---------------------------------------------------------

      else

        throwUserError(
          "Wikimedia login failed: " ..
          tostring(
            result.clientlogin.message
            or status
            or "unknown reason"
          )
        )

        return false
      end
    end

  -------------------------------------------------------------
  -- Bot password
  -------------------------------------------------------------

  else

    local result =
      MediaWikiApi.performRequest {
        action     = "login",
        format     = "json",
        lgname     = username,
        lgpassword = password,
        lgtoken    = login_token
      }

    if result
        and result.login
        and result.login.result ==
          "Success" then

      authenticated = true

      log("bot login successful")

      return true
    end

    throwUserError(
      "Bot login failed: " ..
      tostring(
        result
        and result.login
        and result.login.reason
        or "unknown reason"
      )
    )

    return false
  end
end

-----------------------------------------------------------------------
-- Compatibility helpers retained from original module
-----------------------------------------------------------------------

function MediaWikiApi.urlEncode(str)

  if str then

    str =
      string.gsub(
        str,
        "\n",
        "\r\n"
      )

    str =
      string.gsub(
        str,
        "([^%w %-%_%.%~])",
        function(c)
          return string.format(
            "%%%02X",
            string.byte(c)
          )
        end
      )

    str =
      string.gsub(
        str,
        " ",
        "+"
      )
  end

  return str
end

function MediaWikiApi.createRequestBody(arguments)

  local body = nil

  for key, value in pairs(arguments) do

    if body then
      body = body .. "&"
    else
      body = ""
    end

    body =
      body ..
      MediaWikiApi.urlEncode(key) ..
      "=" ..
      MediaWikiApi.urlEncode(value)
  end

  return body or ""
end

-----------------------------------------------------------------------
-- Debug/development helpers
-----------------------------------------------------------------------

function MediaWikiApi.getDebugFile()
  return debug_file
end

function MediaWikiApi.cleanup()

  remove_file(cookie_file)

  MediaWikiApi.edit_token = nil

  log("session cleanup")
end

return MediaWikiApi
