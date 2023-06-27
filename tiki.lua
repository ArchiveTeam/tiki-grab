dofile("urlcode.lua")
local urlparse = require("socket.url")
local http = require("socket.http")
JSON = (loadfile "JSON.lua")()

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_videos = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false

local current_uid = nil
local video_id = nil

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
end

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
--print('discovered', item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  local other, value = string.match(url, "^https?://tiki.video/@([^/]+)/video/([0-9]+)$")
  local type_ = "video"
  if not value then
    value = string.match(url, "^https?://tiki%.video/@([^/]+)/$")
    type_ = "user"
  end
  if value then
    return {
      ["value"]=value,
      ["type"]=type_,
      ["other"]=other
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found and not ids[found["value"]] then
    item_type = found["type"]
    if item_type == "video" then
      item_value = found["other"] .. ":" .. found["value"]
      video_id = found["value"]
    else
      item_value = found["value"]
    end
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[found["value"]] = true
      abortgrab = false
      initial_allowed = false
      current_uid = nil
      tries = 0
      retry_url = false
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[url]
    or string.match(url, "^https?://api%.tiki%.video/")
    or string.match(url, "^https?://img%.tiki%.video/")
    or string.match(url, "^https?://videosnap%.tiki%.video/") then
    return true
  end

  if not string.match(url, "^https?://.")
    or string.match(url, "%?lang=[a-z]+$") then
    return false
  end

  if select(2, string.gsub(url, "/", "")) < 3 then
    url = url .. "/"
  end

  for _, pattern in pairs({
    "@([^/%?&]+)",
    "([0-9]+)"
  }) do
    for s in string.gmatch(string.match(url, "^https?://[^/]+(/.*)"), pattern) do
      if ids[s] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  --[[if allowed(url, parent["url"]) and not processed(url) then
    addedtolist[url] = true
    return true
  end]]

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  
  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function decode_codepoint(newurl)
    newurl = string.gsub(
      newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
      function (s)
        return unicode_codepoint_as_utf8(tonumber(s, 16))
      end
    )
    return newurl
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://.") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl)
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      table.insert(urls, { url=url_ })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function post_request(newurl, data)
    local data = JSON:encode(data)
    local check_s = newurl .. data
    if not processed(check_s) then
      print("POST to " .. newurl .. " with data " .. data)
      table.insert(urls, {
        url=newurl,
        method="POST",
        body_data=data,
        headers={
          ["Accept"]="application/json",
          ["Content-Type"]="application/json"
        }
      })
      addedtolist[check_s] = true
    end
  end

  local function checknewurl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  if allowed(url)
    and status_code < 300
    and not string.match(url, "^https?://img%.tiki%.video/")
    and not string.match(url, "^https?://videosnap%.tiki%.video/")
    and not string.match(url, "^https?://video%.tiki%.video/") then
    html = read_file(file)
    if string.match(url, "/@[^/]+/?$") then
      local data = string.match(html, 'window%.data%s*=%s*({.-});')
      local json = JSON:decode(data)
      assert(json["userinfo"]["tikiuid"] == json["userinfo"]["nick_name"])
      assert(json["userinfo"]["tikiuid"] == json["userinfo"]["tikiId"])
      ids[json["userinfo"]["tikiuid"]] = true
      check(urlparse.absolute(url, "/@" .. json["userinfo"]["tikiuid"]) .. "/")
      current_uid = json["userinfo"]["uid"]
      local uid_table = {["uid"]=current_uid}
      post_request(
        "https://api.tiki.video/tiki-micro-flow-client/userApi/getUserFollow",
        uid_table
      )
      post_request(
        "https://api.tiki.video/tiki-micro-flow-client/userApi/getUserPostNum",
        uid_table
      )
      for _, lab_type in pairs({0}) do--, 1}) do
        post_request(
          "https://api.tiki.video/tiki-micro-flow-client/videoApi/getUserVideo",
          {
            ["uid"]=current_uid,
            ["count"]=12,
            ["tabType"]=lab_type,
            ["lastPostId"]=0
          }
        )
      end
    end
    if string.match(url, "/@[^/]+/video/[0-9]+$") then
      local data = string.match(html, 'window%.data%s*=%s*({.-});')
      local json = JSON:decode(data)
      check(json["coverUrl"])
      check(json["coverUrl"] .. "&dw=540&resize=21")
      discover_item(discovered_videos, "video-url:" .. json["videoUrl"])
      post_request(
        "https://api.tiki.video/tiki-micro-flow-client/videoApi/getVideoInfo",
        {
          ["postIds"]=video_id
        }
      )
      post_request(
        "https://api.tiki.video/tiki-micro-flow-client/videoApi/getVideoComment",
        {
          ["post_id"]=video_id,
          ["page_size"]=10,
          ["last_comment_id"]="0"
        }
      )
      return urls
    end
    if string.match(url, "/videoApi/getVideoComment") then
      local json = JSON:decode(html)
      local last_id = nil
      for _, data in pairs(json["data"]) do
        last_id = data["commentId"]
      end
      if last_id ~= nil then
        post_request(
          "https://api.tiki.video/tiki-micro-flow-client/videoApi/getVideoComment",
          {
            ["post_id"]=video_id,
            ["page_size"]=10,
            ["last_comment_id"]=last_id
          }
        )
      end
    end
    if string.match(url, "/videoApi/getUserVideo") then
      local json = JSON:decode(html)
      local is_owned = true
      local last_id = nil
      for _, data in pairs(json["data"]["videoList"]) do
        if not ids[data["tikiId"]]
          and not ids[data["nickname"]] then
          is_owned = false
        end
        last_id = data["postId"]
        discover_item(discovered_items, "video:" .. data["tikiId"] .. ":" .. data["postId"])
      end
      if last_id ~= nil then
        local lab_type = 0
        if not is_owned then
          lab_type = 1
        end
        if lab_type == 0 then
          post_request(
            "https://api.tiki.video/tiki-micro-flow-client/videoApi/getUserVideo",
            {
              ["uid"]=current_uid,
              ["count"]=12,
              ["tabType"]=lab_type,
              ["lastPostId"]=last_id
            }
          )
        end
      end
    end
    if string.match(url, "^https?://api%.tiki%.video/") then
      return urls
    end
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
    html = string.gsub(html, "&gt;", ">")
    html = string.gsub(html, "&lt;", "<")
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  if http_stat["statcode"] == 404
    and string.match(url["url"], "/@[0-9]+/$") then
    abort_item()
    return false
  end
  if http_stat["statcode"] ~= 200 then
    retry_url = true
    return false
  end
  if string.match(url["url"], "^https?://api%.tiki%.video/") then
    local html = read_file(http_stat["local_file"])
    if not string.match(html, "^%s*{")
      or not string.match(html, "}%s*$") then
      print("Did not get JSON data.")
      retry_url = true
      return false
    end
    local json = JSON:decode(html)
    if json["code"] ~= 0
      or json["message"] ~= "ok" then
      print("Bad code in JSON.")
      retry_url = true
      return false
    end
  elseif string.match(url["url"], "^https?://tiki%.video/") then
    local html = read_file(http_stat["local_file"])
    if not string.match(html, "</html>") then
      print("Bad HTML.")
      retry_url = true
      return false
    end
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]
  
  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end
  
  if status_code < 400 then
    downloaded[url["url"]] = true
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    if tries > 5 then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 10
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and JSON:decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["tiki-4576gad2rplbbr9y"] = discovered_items,
    ["tiki-videos-lep30wa643shp7a4"] = discovered_videos
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


