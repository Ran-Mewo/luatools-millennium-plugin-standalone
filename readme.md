# LuaTools Millennium Plugin

Standalone LuaTools plugin for Millennium 3.4 and later. It does not use or start `LuaTools.exe`.

## Install

1. Install dependencies with `npm install`.
2. Run `npx starlight pack --release`.
3. Copy `luatools.star` to `<Steam>/millennium/plugins/`.
4. Remove any old `<Steam>/millennium/plugins/luatools/` folder before starting Steam.

On the configured Windows development install, `scripts/deploy.ps1` builds and installs the package. It refuses to install while the old loose-file plugin folder exists.

The plugin downloads and installs game Lua scripts directly through Millennium.

## LuaTools account

When the plugin loads without a saved session, it opens Discord sign-in in your browser. Luie requires this login; the other sources remain usable without it. Settings shows your account status and lets you sign in again or sign out.

Login uses a local callback at `http://localhost:53789/callback`. Close any other LuaTools login flow if that port is already in use. Saved tokens are encrypted for your Windows account with DPAPI under `%LOCALAPPDATA%\LuaToolsPlugin\auth.dat` and refreshed automatically. Signing out removes the local session; the next plugin load opens sign-in again.

Luie downloads use your LuaTools account's download allowance.
