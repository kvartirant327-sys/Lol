--[[
    rainworld example — builds the whole interface from the design.
    Run it in your executor; RightShift opens and closes the menu.
]]

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/kvartirant327-sys/Lol/HEAD/Library.lua"))()

-- Everything is saved under this workspace folder (fonts, configs, scripts).
Library.Name = "rainworld"
Library.Folder = "rainworld"

--// Menu ------------------------------------------------------------------------

local Window = Library:Window({ Name = "rainworld" })

local Aimbot = Window:Tab("aimbot")
local Rage = Window:Tab("rage")
local Esp = Window:Tab("esp")
local Visuals = Window:Tab("visuals")
local Misc = Window:Tab("misc")

-- aimbot: the two sections from the design
local AimAssist = Aimbot:Section({ Name = "aim assist", Side = "left" })

local Enabled = AimAssist:Toggle({
    Name = "enabled",
    Flag = "aim_enabled",
    Default = true,
    Callback = function(value)
        print("aim assist:", value)
    end,
})
Enabled:Colorpicker({ Flag = "aim_color", Default = Color3.fromRGB(153, 129, 188) })
Enabled:Colorpicker({ Flag = "aim_fov_color", Default = Color3.fromRGB(200, 162, 255) })
-- Display = false keeps the key out of the row: right-click the toggle to bind it.
local AimKey = Enabled:Keybind({ Name = "aim assist", Flag = "aim_key", Mode = "Hold", Display = false })

AimAssist:Slider({ Name = "speed", Flag = "aim_speed", Min = 0, Max = 100, Default = 10, Suffix = "%" })
AimAssist:Dropdown({
    Name = "smoothing",
    Flag = "aim_smoothing",
    Options = { "inertial", "linear", "quadratic", "exponential" },
    Default = "inertial",
})
AimAssist:Button({
    Name = "button",
    Callback = function()
        Library:Notify({ "pressed ", { "button" } })
    end,
})

local Triggerbot = Aimbot:Section({ Name = "triggerbot", Side = "right" })
Triggerbot:Toggle({ Name = "toggle", Flag = "trigger_enabled", Default = true })

-- rage: the rest of the element set
local Elements = Rage:Section({ Name = "elements", Side = "left" })
Elements:Slider({ Name = "range", Flag = "demo_range", Min = 0, Max = 100, Default = { 9, 71 }, Range = true })
Elements:Slider({ Name = "amount", Flag = "demo_amount", Min = 0, Max = 100, Step = 0.1, Default = 73.7 })
Elements:Dropdown({
    Name = "hitboxes",
    Flag = "demo_hitboxes",
    Options = { "head", "chest", "stomach", "arms", "legs" },
    Default = { "head", "chest" },
    Multi = true,
})
Elements:Textbox({ Name = "text", Flag = "demo_text", Placeholder = "type here" })
Elements:Label({ Name = "menu bind" }):Keybind({ Name = "example bind", Flag = "demo_bind", Default = Enum.KeyCode.X })
Elements:Colorpicker({ Name = "colour", Flag = "demo_color", Default = Color3.fromRGB(255, 80, 80), Transparency = 0.25 })
Elements:Divider("buttons")
Elements:Button({ Name = "button" })
Elements:DoubleButton({ Name = "button" }, { Name = "button" })
Elements:TripleButton({ Name = "button" }, { Name = "button" }, { Name = "button" })

local Lists = Rage:Section({ Name = "list", Side = "right" })
Lists:List({
    Name = "players",
    Flag = "demo_player",
    Height = 120,
    Options = { "nova", "wraith", "silhouette", "kestrel", "ember", "vellum", "harrow" },
    Save = false,
})

-- esp / visuals: plain toggles with colours, as a script would use them
local Players = Esp:Section({ Name = "players", Side = "left" })
for _, name in { "box", "name", "health bar", "distance", "weapon", "skeleton" } do
    local toggle = Players:Toggle({ Name = name, Flag = "esp_" .. string.gsub(name, " ", "_") })
    toggle:Colorpicker({ Flag = "esp_" .. string.gsub(name, " ", "_") .. "_color", Default = Color3.fromRGB(255, 255, 255) })
end

local World = Visuals:Section({ Name = "world", Side = "left" })
World:Toggle({ Name = "fullbright", Flag = "world_fullbright" })
World:Slider({ Name = "brightness", Flag = "world_brightness", Min = 0, Max = 10, Step = 0.5, Default = 2 })
World:Slider({ Name = "field of view", Flag = "world_fov", Min = 30, Max = 120, Default = 70, Suffix = "°" })

--// Hud and windows -------------------------------------------------------------

local Watermark = Library:Watermark({
    Name = "rainworld.club",
    Tag = "$$$",
    Stats = { "ram", "fps", "ping" },
    -- Animation = "Bounce",
    -- NameColor = Color3.new(1, 1, 1), DomainColor = Color3.fromRGB(201, 164, 253),
})

local Keybinds = Library:KeybindList({ Name = "keybinds", Mode = "All" })
local Hitlogs = Library:Hitlogs({ Side = "Left", Animation = "Slide" })
local Target = Library:TargetHud({ Mode = "Static" })
local Preview = Library:EspPreview({ Name = "esp preview", Text = "no preview for ya today" })
local Configs = Library:Configs()
local Lua = Library:Lua()
local Dock = Library:Dock({ Name = "rainworld.club", Mode = "Top" })
local Theme = Library:ThemeWindow() -- create last: it lists settings for the pieces above

Dock:Add("menu", Window)
Dock:Add("watermark", Watermark)
Dock:Add("preview", Preview)
Dock:Add("configs", Configs)
Dock:Add("lua", Lua)
Dock:Add("theme", Theme)
Dock:Add("keybinds", Keybinds)
Dock:Add("hitlogs", Hitlogs)
Dock:Add("target", Target)

--// Wiring ----------------------------------------------------------------------

local Settings = Misc:Section({ Name = "demo", Side = "left" })
Settings:Button({
    Name = "test hitlog",
    Callback = function()
        Hitlogs:Add({ "hit ", { "cursedbullet" }, " in the ", { "head" }, " for ", { "100", Color3.fromRGB(120, 220, 110) } })
    end,
})
Settings:DoubleButton({
    Name = "target me",
    Callback = function()
        Target:SetTarget(game:GetService("Players").LocalPlayer)
    end,
}, {
    Name = "clear target",
    Callback = function()
        Target:SetTarget(nil)
    end,
})
Settings:Button({
    Name = "unload",
    Callback = function()
        Library:Unload()
    end,
})

-- Values live in Library.Flags; listen to one flag or to all of them.
Library:OnChanged("aim_speed", function(value)
    print("speed is now", value)
end)
AimKey.Changed:Connect(function(active)
    print("aim key", active and "held" or "released")
end)

Library:LoadAutoload()
Library:Notify({ "loaded ", { Library.Name }, " - press ", { "right shift" }, " to toggle the menu" })
