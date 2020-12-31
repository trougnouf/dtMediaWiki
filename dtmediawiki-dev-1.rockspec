package = "dtmediawiki"
version = "dev-1"
source = {
   url = "git+ssh://git@github.com/trougnouf/dtMediaWiki.git",
}
description = {
   summary = "Wikimedia Commons export plugin for [darktable](https://www.darktable.org/)",
   detailed = "Wikimedia Commons export plugin for [darktable](https://www.darktable.org/)",
   homepage = "https://github.com/trougnouf/dtMediaWiki",
   license = "GPLv3",
}
dependencies = {
  "luajson",
  "luasec",
  "multipart-post",
}
build = {
   type = "builtin",
   modules = {
      dtMediaWiki = "dtMediaWiki.lua",
      mediawikiapi = "lib/mediawikiapi.lua",
   },
}
