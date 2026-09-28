# dtMediaWiki

Wikimedia Commons export plugin for [darktable](https://www.darktable.org/)

![screenshot](https://upload.wikimedia.org/wikipedia/commons/1/16/DtMediaWiki69--preferences-and-categories.png)

See also: [Commons:DtMediaWiki](https://commons.wikimedia.org/wiki/Commons:DtMediaWiki)

## Dependencies

- [curl](https://curl.se/) available through `PATH`

The MediaWiki backend uses curl for HTTPS communication, session handling,
and multipart uploads. JSON support is bundled with the plugin.

The previous external Lua dependencies `lua-sec`, `lua-luajson`, and
`lua-multipart-post` are no longer required.

Note that `mediawikiapi.lua` is independent of darktable.

## Installation (per user, without root)

- Clone or download the plugin, e.g. to `~/src/dtMediaWiki`
  - `$ git clone https://github.com/trougnouf/dtMediaWiki.git ~/src/dtMediaWiki`
- Link it into your darktable configuration directory
  - `$ mkdir -p ~/.config/darktable/lua/contrib`
  - `$ ln -s ~/src/dtMediaWiki ~/.config/darktable/lua/contrib/dtMediaWiki`
  - Translations are only found in this location, as the plugin loads its
    catalogs relative to the darktable configuration directory.
- Activate the plugin in your darktable luarc config file
  - `$ echo 'require "contrib/dtMediaWiki/dtMediaWiki"' >> ~/.config/darktable/luarc`
- Restart darktable. With a git checkout, `git pull` and a restart update the plugin.

## Installation (system-wide)

- Download the plugin from [https://github.com/trougnouf/dtMediaWiki/archive/master.zip](https://github.com/trougnouf/dtMediaWiki/archive/master.zip)
- Create the [darktable plugin directory](https://www.darktable.org/usermanual/en/lua_chapter.html#lua_usage) if it doesn't exist
  - `# mkdir /usr/share/darktable/lua/contrib`
- Copy (or link) the dtMediaWiki directory over there
  - `# cp -r /path/to/dtMediaWiki /usr/share/darktable/lua/contrib`
  - Keep the directory name `dtMediaWiki`, as the plugin loads its modules
    and translation catalogs relative to `contrib/dtMediaWiki`.
- Activate the plugin in your darktable luarc config file by adding `require "contrib/dtMediaWiki/dtMediaWiki"`
  - `$ echo 'require "contrib/dtMediaWiki/dtMediaWiki"' >> ~/.config/darktable/luarc`

… or simply use the [Arch Linux package](https://aur.archlinux.org/packages/darktable-plugin-dtmediawiki-git/) or [Gentoo package](https://github.com/gentoo/guru/tree/master/media-plugins/dtmediawiki) and activate the plugin.

## Usage

- Login to Wikimedia Commons by setting your "Wikimedia username" and
  "Wikimedia password" in darktable preferences > lua options, then restart
  darktable.
  - The backend uses the MediaWiki ClientLogin API and supports login
    continuations.
  - This will add the "Wikimedia Commons" entry into target storage.
  - Instead of your main password, you can use a bot password, see below.
- Ensure your image contains the following [metadata](https://docs.darktable.org/usermanual/stable/en/module-reference/utility-modules/shared/metadata-editor/) and [tags](https://docs.darktable.org/usermanual/stable/en/module-reference/utility-modules/shared/tagging/):
  - **title** and/or **description** – The default output filename is `title (filename) description.ext` or `title (filename).ext` depending on what is available
  - **rights** – Use something compatible with the [`{{self}}`](https://commons.wikimedia.org/wiki/Template:Self) template, some options are [`cc-by-sa-4.0`](https://commons.wikimedia.org/wiki/Template:Cc-by-sa-4.0), [`cc-by-4.0`](https://commons.wikimedia.org/wiki/Template:Cc-by-4.0), [`GFDL`](https://commons.wikimedia.org/wiki/Template:GFDL), see [Commons:Copyright tags](https://commons.wikimedia.org/wiki/Commons:Copyright_tags)
  - **tags** – Categories and templates. Any tag that matches `Category:something` will be added as `[[Category:something]]` (no need to include the brackets), likewise any template matching `{{something}}` will be added as-is.

The image coordinates will be added if they exist, and the creator metadata will be added as `[[User:Wikimedia username|creator]]` if it has been set.

### Bot password (app-specific password)

The password is stored in plain text in the darktable configuration. A bot
password limits what it can be used for and can be revoked at any time
without changing your main password.

- Log in to Wikimedia Commons and open
  [Special:BotPasswords](https://commons.wikimedia.org/wiki/Special:BotPasswords)
- Enter a bot name, e.g. `dtMediaWiki`, and click "Create"
- Grant at least the following permissions:
  - **Edit existing pages**
  - **Create, edit, and move pages**
  - **Upload new files**
  - **Upload, replace, and move files** (only needed for the "overwrite" preference)
- Click "Create" and note the generated password; it is only shown once
- In darktable preferences > lua options, set
  - "Wikimedia username" to `YourUsername@dtMediaWiki` (as shown on the
    confirmation page)
  - "Wikimedia password" to the generated password

A username containing `@` is logged in via the MediaWiki `action=login` API
instead of ClientLogin.

## Commons metadata

dtMediaWiki provides a per-image Commons metadata editor in the lighttable
view. It supports localized descriptions, templates, categories, Wikidata,
other versions, and additional Commons fields.

Metadata can be edited for multiple selected images and copied between
images. Named metadata presets can be saved and applied to selected images.

The "Wikimedia Commons category search" module in the lighttable view
searches Commons categories. Clicking a result adds that category to all
selected images; the ↗ button next to it opens the category in the web
browser.

The export dialog supports global categories and additional templates or
wikitext. Filename patterns can use image metadata placeholders including
title, descriptions, capture date, camera and lens information, exposure
data, and GPS information when available.

## Translations

The dtMediaWiki user interface supports gettext translations. Every
translatable string is wrapped in the Lua source: as `_("...")` in the
`lib/` modules, and as `translate("...")` in `dtMediaWiki.lua`. The
translation catalogs in the `locale` directory are maintained by
`tools/update-translations.py`, which extracts the strings from the source,
updates the `.pot` and per-language `.po` files, and compiles the `.mo`
binaries:

```
python3 tools/update-translations.py
```

Run it whenever you add, change, or remove a wrapped string, and commit the
resulting `locale/` changes together with your code change. Do not edit the
`.pot`, `.po`, or `.mo` files by hand. `--check` verifies that the catalogs
are in sync with the source (this is also run in CI):

```
python3 tools/update-translations.py --check
```

Translations are coordinated on [Transifex](https://www.transifex.com/) (see
`.tx/config`).

## See also

All tools for uploading to Wikimedia Commons https://commons.wikimedia.org/wiki/Commons:Upload_tools

## Thanks

- Iulia and Leslie for excellent coworking companionship and love
- darktable developers for an excellent open-source imaging software with a well documented [Lua API](https://docs.darktable.org/lua/stable/)
- [LrMediaWiki](https://github.com/Hasenlaeufer/LrMediaWiki) developers [robinkrahl](https://github.com/robinkrahl) and [Hasenlaeufer](https://github.com/Hasenlaeufer) for what inspired this and some base code
- MediaWiki [User:Platonides](https://www.mediawiki.org/wiki/User:Platonides) for helping me figure out the cookie issue
- [catwell](https://github.com/catwell): author of lua-multipart-post and a responsive fellow
- [simon04](https://github.com/simon04): second user and first contributor

![:)](https://upload.wikimedia.org/wikipedia/commons/3/30/Binette-typo.png)

--[Trougnouf](https://commons.wikimedia.org/wiki/User:Trougnouf)
