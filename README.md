# dtMediaWiki
MediaWiki for darktable (work-in-progress)

Dependencies:

* lua-sec: Lua bindings for OpenSSL library to provide TLS/SSL communication (mediawikiapi.lua)
* lua-multipart-post: HTTP Multipart Post helper for lua (mediawikiapi.lua)
* lua-luajson: JSON parser/encoder for Lua (mediawikiapi.lua)
* darktable-lua-scripts-git: Lua scripts extending darktable (dtMediaWiki.lua)

current instal method:

* \# mkdir /usr/share/darktable/lua/contrib
* \# ln -s /path/to/dtMediaWiki /usr/share/darktable/lua/contrib
* $ echo 'require "contrib/dtMediaWiki/dtMediaWiki"' >> ~/.config/darktable/luarc