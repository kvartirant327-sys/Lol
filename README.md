# rainworld

A Roblox UI library for executors, built 1:1 from the rainworld Figma design: a tabbed menu, a dock,
a watermark, a keybind list, hitlogs, a target hud, an esp preview, a config manager and a lua
editor. Every colour, font and text size can be changed at runtime.

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/kvartirant327-sys/Lol/HEAD/Library.lua"))()
```

[`Example.lua`](Example.lua) builds the whole interface from the design and is the quickest way to
see everything working. **RightShift** opens and closes the menu.

- [Menu](#menu) · [Elements](#elements) · [Flags and callbacks](#flags-and-callbacks) · [Configs](#configs)
- [Hud](#hud): [watermark](#watermark), [keybind list](#keybind-list), [hitlogs](#hitlogs), [target hud](#target-hud)
- [Windows](#windows): [dock](#dock), [esp preview](#esp-preview), [configs](#configs-window), [lua](#lua-window), [theme](#theme-window)
- [Lua api](#lua-api) · [Customising](#customising) · [Executor functions](#executor-functions)

Option tables are case-insensitive (`Name` and `name` are the same), and a plain string works
wherever only a name is needed: `Window:Tab("aimbot")`.

## Menu

```lua
local Window = Library:Window({ Name = "rainworld" })            -- Size, Position, Columns = 2

local Aimbot = Window:Tab("aimbot")                              -- Columns overrides the window's
local Section = Aimbot:Section({ Name = "aim assist", Side = "left" })
```

Sections go in the `"left"` or `"right"` column (or `Column = n` when a tab has more). A section
fills the space left in its column; pass `Height = 150` for a fixed height or `Height = "auto"` to
fit its content. Sections scroll when their content is taller than they are.

`Window:SetVisible(bool)`, `:Toggle()`, `:SetName(text)`, `:SetSize(Vector2)`,
`:SetPosition(Vector2)` and `:SelectTab(name)` do what they say. Windows are dragged by their
header.

## Elements

```lua
local Toggle = Section:Toggle({ Name = "enabled", Flag = "aim_enabled", Default = true,
    Callback = function(value) end })

Section:Slider({ Name = "speed", Flag = "aim_speed", Min = 0, Max = 100, Default = 10, Suffix = "%" })
Section:Slider({ Name = "amount", Flag = "amount", Min = 0, Max = 100, Step = 0.1, Default = 73.7 })
Section:Slider({ Name = "range", Flag = "range", Min = 0, Max = 100, Default = { 9, 71 }, Range = true })

Section:Dropdown({ Name = "smoothing", Flag = "smoothing", Options = { "inertial", "linear" }, Default = "inertial" })
Section:Dropdown({ Name = "hitboxes", Flag = "hitboxes", Options = { "head", "chest", "legs" }, Multi = true })

Section:Textbox({ Name = "text", Flag = "text", Placeholder = "type here" })   -- Numeric = true for numbers
Section:List({ Name = "players", Flag = "player", Options = { "nova", "wraith" }, Height = 120 })

Section:Button({ Name = "button", Callback = function() end })
Section:DoubleButton({ Name = "load" }, { Name = "save" })
Section:TripleButton({ Name = "a" }, { Name = "b" }, { Name = "c" })
Section:Buttons({ { Name = "any" }, { Name = "number" }, { Name = "of" }, { Name = "buttons" } })

Section:Label({ Name = "just text" })
Section:Divider("caption")                                       -- or Section:Divider() for a plain line
Section:Colorpicker({ Name = "colour", Flag = "colour", Default = Color3.fromRGB(255, 80, 80), Transparency = 0.25 })
Section:Keybind({ Name = "menu bind", Flag = "bind", Default = Enum.KeyCode.X, Mode = "Toggle" })
```

Toggles and labels take colour pickers and a keybind on their right side:

```lua
Toggle:Colorpicker({ Flag = "aim_color", Default = Color3.fromRGB(153, 129, 188) })
Toggle:Keybind({ Name = "aim assist", Flag = "aim_key", Mode = "Hold" })
```

| Element | Notes |
| --- | --- |
| Slider | Drag the bar or use the `−` / `+` ends to step. `Range = true` makes a two-ended slider. |
| Dropdown | `Multi = true` keeps it open and returns a list. `:SetOptions(list)` (alias `:Refresh`) replaces the options. |
| Colour picker | Opens docked to the left of the menu, as in the design. Passing `Transparency` adds the transparency strip. |
| Keybind | Click and press a key (or mouse button 2/3) to bind; Escape clears. Right-click picks `Toggle`, `Hold` or `Always`. Mouse buttons are saved too. |

Keybind options: `Mode`, `Callback(active)`, `KeyChanged(key)`, `Sync = true` (the bind drives its
toggle), `Hidden = true` (keep it out of the keybind list), `Modes = false` (no mode popup) and
`Display = false` (no key text in the row — bind by right-clicking the toggle, which is how the
design's `enabled` row works). `keybind:IsActive()` is true when the key is active *and* the
toggle it is attached to is on.

Every element has `:Set(value)`, `:Get()`, `:SetVisible(bool)` and `:OnChanged(callback)`.
Toggle, slider, dropdown and colour picker callbacks also run once when the element is created,
with its default value. `Save = false` keeps an element out of configs.

## Flags and callbacks

An element with a `Flag` publishes its value in `Library.Flags` and itself in `Library.Options`:

```lua
if Library.Flags.aim_enabled and Library.Flags.aim_key.Active then
    local speed = Library.Flags.aim_speed
end

Library.Options.aim_speed:Set(50)

local disconnect = Library:OnChanged("aim_speed", function(value) end)
Library.Changed:Connect(function(flag, value) end)               -- every flag
```

| Element | Value in `Library.Flags` |
| --- | --- |
| Toggle | `boolean` |
| Slider | `number`, or `{ Min = n, Max = n }` for a range |
| Dropdown, List | the option, or a list of options for `Multi` |
| Textbox | `string` |
| Colour picker | `{ Color = Color3, Transparency = number }` |
| Keybind | `{ Key = EnumItem?, Mode = string, Active = boolean }` |

## Configs

Configs are JSON files in `<Library.Folder>/configs`. They hold every flag, plus window positions,
visibility and the theme; set `Library.SaveInterface = false` to keep those last three out.

```lua
Library:SaveConfig("legit")        -- no name: next free number ("1", "2", ...) and returns it
Library:LoadConfigFile("legit")
Library:DeleteConfig("legit")
Library:ListConfigs()              -- { "1", "2", "legit" }

Library:SetAutoload("legit")       -- remembered in <Folder>/autoload.txt
Library:LoadAutoload()             -- call once, after building the menu

local json = Library:GetConfig()   -- the same data as a string, e.g. for the clipboard
Library:LoadConfig(json)
```

On executors without a filesystem configs are kept in memory for the session.

## Hud

Hud pieces stay on screen while the menu is closed and can be dragged while it is open. Their
positions are saved with configs. All of them have `:SetVisible(bool)`, `:Toggle()` and
`:SetPosition(Vector2)`.

### Watermark

```lua
local Watermark = Library:Watermark({
    Name = "rainworld.club",
    Tag = "$$$",                          -- optional, shown after a divider
    Stats = { "ram", "fps", "ping" },     -- also "time", "date", "user", "executor", or functions
    Animation = "None",                   -- "Bounce", "Wave" or "Shine"
})
```

By default the name is drawn with the design's gradient (accent at both ends, near-white in the
middle). To colour it yourself:

```lua
-- a domain: everything before the first dot, and the dot onwards
Library:Watermark({ Name = "drain.solutions", NameColor = Color3.new(1, 1, 1), DomainColor = Color3.fromRGB(190, 120, 255) })

-- any split, any number of parts; a colour can also be a theme key such as "accent"
Library:Watermark({ Name = { { "sharik", Color3.new(1, 1, 1) }, { "tools", Color3.fromRGB(255, 150, 40) } } })
```

`Watermark:SetName(options)` takes the same options later, `:SetAnimation(name, speed)` changes
the animation and `:SetStats(list)` the stats. Add your own stat with
`Library.StatProviders.kills = function() return "12 kills" end` and list it as `"kills"`.

### Keybind list

```lua
local Keybinds = Library:KeybindList({
    Mode = "All",                  -- "All": every bind, active ones highlighted; "Active": only active binds
    ShowKeys = true,               -- the "- [key]" part
    KeyColor = nil,                -- a colour just for the keys (nil: same as the row)
    ActiveColor = "accent_text",   -- highlight for active binds in "All" mode
})
```

`:SetMode`, `:SetShowKeys`, `:SetKeyColor` and `:SetActiveColor` change these later.
`ShowModes = true` adds `(hold)` / `(toggle)` after each name.

### Hitlogs

```lua
local Hitlogs = Library:Hitlogs({
    Side = "Left",                 -- edge the entries fly in from: "Left", "Right", "Top", "Bottom"
    Animation = "Slide",           -- "Slide", "Bounce", "Back" or "Fade"
    Duration = 4, Max = 6,
})

Hitlogs:Add("plain text")
Hitlogs:Add({ "hit ", { "player" }, " in the ", { "head" }, " for ", { "100", Color3.fromRGB(120, 220, 110) } })
```

`{ text }` is drawn in the accent colour and `{ text, colour }` in your own. While the menu is
open a small `hitlogs` handle shows where the stack starts; drag it to move the stack.
`Library:Notify(parts, duration)` is a shortcut that uses the hitlogs when they exist.

### Target hud

```lua
local Target = Library:TargetHud({
    Mode = "Static",               -- or "Attached": follows the target on screen
    Offset = Vector2.new(40, -30), -- from the target, in "Attached" mode
    Stats = { "health", "distance", function(target, character) return "custom" end },
    Role = function(player) return "admin" end,     -- or GroupId = 123 to show the group role
    Armor = function(target, character) return 50, 100 end,
    Elements = { Avatar = true, Name = true, Role = true, Stats = true, Health = true, Armor = true },
})

Target:SetTarget(player)           -- a Player or a character model; nil clears it
Target:SetInfo("weapon", "ak-47")  -- extra line; nil removes it
```

`:SetMode(mode)`, `:SetElement("avatar", false)` and `:SetArmor(value, max)` are also available.
While the menu is open and there is no target, the hud shows you so it can be positioned.

## Windows

Windows are only visible while the menu is open.

### Dock

```lua
local Dock = Library:Dock({ Name = "rainworld.club", Mode = "Top" })   -- or "Float"
Dock:Add("menu", Window)           -- anything with :SetVisible, including hud pieces
Dock:Add("panic", function() Library:Unload() end)
Dock:Add("esp", { Get = function() return enabled end, Set = function(value) enabled = value end })
```

`"Top"` pins the bar across the top edge of the screen; `"Float"` makes it a compact bar in the
upper centre that can be dragged. `Dock:SetMode(mode)` switches at runtime. Items are lit when
their target is on. The name takes the same colouring options as the watermark.

### Esp preview

```lua
local Preview = Library:EspPreview({ Name = "esp preview", Text = "no preview for ya today" })
Preview:SetImage("rbxassetid://123")   -- or an http(s) image url
Preview:SetCharacter(character)        -- a model in a viewport; your own character by default
```

`Preview.Holder` is the content frame — parent your own preview boxes and labels to it.

### Configs window

`Library:Configs()` is the config list from the design: **Load** and **Delete** act on the
selected config, **Save** stores the current settings as a new one, **Rewrite** overwrites the
selected one and **Refresh** re-reads the folder.

### Lua window

`Library:Lua()` is the script editor. **Execute** runs the editor's contents with the
[lua api](#lua-api); **Save** writes them to `<Folder>/scripts/main.lua`, which is loaded back
into the editor next time. Options: `File = "main"`, `AutoExecute = true`, `Placeholder`.

### Theme window

`Library:ThemeWindow()` builds a settings window with a colour picker for every theme colour, the
presets, the menu key, ui scale, text size preset and the options of the dock and hud pieces.
Create it **after** them — it only lists what already exists — and add it to the dock.

`Library:MobileButton()` adds a small draggable button that toggles the menu; it is created
automatically on touch devices without a keyboard.

## Lua api

Scripts run from the lua window (or with `Library:RunScript(source, name)`) get an `api` table.
Its functions are also globals, alongside `library` and `flags`:

```lua
api.set("aim_speed", 42)                         -- through the element, so the menu updates
print(api.get("aim_speed"), flags.aim_enabled)

api.on("aim_speed", function(value) end)         -- a flag
api.on("render", function(delta) end)            -- also "heartbeat", "open", "config", "unload"
api.connect(workspace.ChildAdded, function() end)

notify({ "hello from ", { "lua" } })

local tab = api.tab("scripts")                   -- finds or creates a menu tab
tab:Section({ Name = "my script" }):Toggle({ Name = "thing", Flag = "my_thing" })
```

Everything connected through `api.on` and `api.connect` is disconnected when the script is run
again, when `api.unload()` is called, or when the library unloads.

## Customising

### Colours

```lua
Library:SetTheme("accent", Color3.fromRGB(150, 200, 60))
Library:ApplyTheme("gamesense")                  -- rainworld, gamesense, fatality, neverlose, onetap, blood, mono
Library:ApplyTheme({ accent = Color3.new(1, 0, 0), background = Color3.fromRGB(10, 10, 10) })
Library.Presets.mine = { accent = Color3.new(1, 0, 0) }
```

Theme keys: `accent`, `accent_text`, `text`, `text_dim`, `text_outline`, `outline`, `inline`,
`background`, `border`, `page`, `section`, `section_inline`, `element`, `element_outline`,
`button_top`, `button_bottom`, `button_outline`, `track`, `dock`, `panel_inline`.

### Fonts and text sizes

Every piece of text has a role in `Library.Text`. Change a role at any time:

```lua
Library:SetText("text", { Size = 12 })
Library:SetText("title", { Font = "TahomaBold", Size = 12 })
```

| Role | Used for | Default |
| --- | --- | --- |
| `title` | menu title | ProggyClean 12 |
| `tab` | tab names | ProggyClean 10 |
| `section` | section headers | ProggyClean 8 |
| `text` | element labels and values | ProggyClean 9 |
| `button` | buttons | ProggyClean 10 |
| `hud` | keybind list, hitlogs, target hud | ProggyClean 10 |
| `watermark` | watermark stats | ProggyClean 9 |
| `dock` | dock items | ProggyClean 12 |
| `brand`, `watermark_brand` | the name on the dock / watermark | TahomaBold 11 |
| `preview_title` | esp preview title | TahomaBold 16 |
| `panel_title`, `panel_text` | configs and lua windows | TahomaBold 22, Tahoma 15 |

The sizes follow the Figma file, which draws ProggyClean smaller than its native pixel size.
ProggyClean is only pixel-perfect at size 12, so for sharper (and larger) text set those roles to
12, or pick **crisp** under *text* in the theme window.

Bundled font names: `ProggyClean`, `ProggyTiny`, `TahomaBold`, `Tahoma`, `SmallestPixel`,
`Minecraftia`, `Verdana`. They are downloaded once from
[i77lhm/storage](https://github.com/i77lhm/storage) into `<Folder>/fonts`; point
`Library.FontSource` at your own mirror if you prefer. To add a font:

```lua
Library:RegisterFont("MyFont", "https://example.com/MyFont.ttf")
Library:SetText("text", { Font = "MyFont" })
```

### Everything else

```lua
Library.Name = "rainworld"                -- set these before creating anything
Library.Folder = "rainworld"              -- workspace folder for fonts, configs and scripts
Library.ToggleKey = Enum.KeyCode.Insert

Library:SetScale(1.25)                    -- scales the whole interface
Library:SetOpen(false)                    -- or Library:Toggle()
Library:Unload()                          -- removes everything and disconnects all events
```

Signals: `Library.Changed(flag, value)`, `Library.OpenChanged(open)`,
`Library.ThemeChanged(key, color)`, `Library.ConfigLoaded(name)`, `Library.Unloading()`.

## Executor functions

All optional — the library falls back gracefully when one is missing.

| Function | Used for | Without it |
| --- | --- | --- |
| `gethui`, `cloneref`, `protectgui` | parenting and hiding the interface | CoreGui, then PlayerGui |
| `writefile`, `readfile`, `isfile`, `isfolder`, `makefolder`, `listfiles`, `delfile` | fonts, configs, scripts | configs live in memory |
| `getcustomasset` | custom fonts and preview images | built-in Roblox fonts |
| `loadstring` | the lua window | scripts cannot run |
| `identifyexecutor` | the `executor` watermark stat | shows `unknown` |

## Credits

Fonts are served from [i77lhm/storage](https://github.com/i77lhm/storage); the structure of the
library follows the conventions of [i77lhm/Libraries](https://github.com/i77lhm/Libraries).
