# dtMediaWiki
MediaWiki for darktable. This plugin allows to upload images directly to Wikimedia Commons.

## Dependencies
* lua-sec
	 * Lua bindings for OpenSSL library to provide TLS/SSL communication
* lua-luajson
	 * JSON parser/encoder for Lua

note that mediawiki.lua is independent of darktable.

## Installation
* Download the plugin
	* ie [https://github.com/trougnouf/dtMediaWiki/archive/master.zip](https://github.com/trougnouf/dtMediaWiki/archive/master.zip)
* Create the darktable plugin directory if it doesn't exist
	 * `# mkdir /usr/share/darktable/lua/contrib`
* Copy (or link) the dtMediaWiki directory over there
	 * `# cp -r /path/to/dtMediaWiki /usr/share/darktable/lua/contrib`
* Activate the plugin in your darktable luarc config file by adding `require "contrib/dtMediaWiki/dtMediaWiki"`
	 * `$ echo 'require "contrib/dtMediaWiki/dtMediaWiki"' >> ~/.config/darktable/luarc`

or simply use the [arch installer](https://aur.archlinux.org/packages/darktable-plugin-dtmediawiki-git/) and activate the plugin.

## Usage

* Login to Wikimedia Commons by setting your "Wikimedia username" and "Wikimedia password" in *darktable preferences > lua options* then restarting darktable.
	 * This will add the "Wikimedia commons" entry into target storage.
* Ensure your image metadata contains the following:
	 * a title and/or description.
		 * The current output filename is "title (filename) description.ext" or "title (filename).ext" depending on what is available
	 * rights
		 * use something compatible with the {{[self](https://commons.wikimedia.org/wiki/Template:Self)}} template, some options are "cc-by-sa-4.0", "cc-by-4.0", "GFDL", "GFDL|cc-by-sa-4.0,3.0,2.5,2.0,1.0", ...
	 * tags: Categories and templates
		 * Any tag that matches "Category:something" will be added as [[Category:something]] (no need to include the brackets), likewise any template matching "{{something}}" will be added as-is.

The image coordinates will be added if they exist, and the creator metadata will be added as [[User:Wikimedia username|creator]] if it has been set.
