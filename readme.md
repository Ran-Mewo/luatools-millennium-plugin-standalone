# LuaTools Millennium Plugin

Standalone LuaTools plugin for Millennium 3.4 and later. It does not use or start `LuaTools.exe`.

## Install

1. Install dependencies with `npm install`.
2. Run `npx starlight pack --release`.
3. Copy `luatools.star` to `<Steam>/millennium/plugins/`.
4. Remove any old `<Steam>/millennium/plugins/luatools/` folder before starting Steam.

On the configured Windows development install, `scripts/deploy.ps1` builds and installs the package. It refuses to install while the old loose-file plugin folder exists.

The plugin downloads and installs game Lua scripts directly through Millennium.
