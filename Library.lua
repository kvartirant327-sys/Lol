--!nocheck
--[[
    rainworld — a Roblox UI library for executors.

        local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/kvartirant327-sys/Lol/HEAD/Library.lua"))()

    Everything the library draws reads its colours from Library.Theme and its
    fonts and text sizes from Library.Text, so the whole interface can be
    restyled at runtime. See README.md for the full API.
]]

local cloneref = cloneref or clonereference or function(instance)
    return instance
end

local function Service(name)
    return cloneref(game:GetService(name))
end

local Players = Service("Players")
local UserInputService = Service("UserInputService")
local RunService = Service("RunService")
local TweenService = Service("TweenService")
local HttpService = Service("HttpService")
local GuiService = Service("GuiService")
local Stats = Service("Stats")
local Workspace = Service("Workspace")

local LocalPlayer = Players.LocalPlayer

local rgb = Color3.fromRGB
local fromOffset = UDim2.fromOffset
local WHITE, BLACK = rgb(255, 255, 255), rgb(0, 0, 0)

-- Executor API. Every entry is optional: the library degrades gracefully (no
-- custom fonts, in-memory configs, PlayerGui parent) when one is missing.
local Env = {
    gethui = gethui or get_hidden_gui,
    protectgui = protectgui or protect_gui or (syn and syn.protect_gui),
    getcustomasset = getcustomasset or getsynasset,
    loadstring = loadstring,
    setclipboard = setclipboard or toclipboard or set_clipboard,
    identifyexecutor = identifyexecutor or getexecutorname,
    getgenv = getgenv,
    request = request or http_request or (syn and syn.request),
    isfile = isfile,
    readfile = readfile,
    writefile = writefile,
    delfile = delfile,
    isfolder = isfolder,
    makefolder = makefolder,
    listfiles = listfiles,
}

local Library = {
    Name = "rainworld",
    Version = "1.0.0",
    Folder = "rainworld", -- workspace folder used for fonts, configs and scripts
    FontSource = "https://github.com/i77lhm/storage/raw/refs/heads/main/fonts/",

    Flags = {}, -- flag -> current value
    Options = {}, -- flag -> element object
    Keybinds = {}, -- every keybind element, in creation order
    Panels = {}, -- windows that follow the menu's open state
    Connections = {},

    Open = true,
    ToggleKey = Enum.KeyCode.RightShift,
    Scale = 1,
    Loaded = false,
    Unloaded = false,
}

local Utility = {}
Library.Utility = Utility
Library.Env = Env

--// Signals -----------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ Handlers = {} }, Signal)
end

function Signal:Connect(callback)
    local handlers = self.Handlers
    local connection = { Connected = true, Callback = callback }

    function connection.Disconnect()
        if not connection.Connected then
            return
        end
        connection.Connected = false
        local index = table.find(handlers, connection)
        if index then
            table.remove(handlers, index)
        end
    end

    table.insert(handlers, connection)
    return connection
end

function Signal:Fire(...)
    for _, connection in table.clone(self.Handlers) do
        if connection.Connected then
            task.spawn(connection.Callback, ...)
        end
    end
end

Library.Signal = Signal
Library.Changed = Signal.new() -- (flag, value)
Library.OpenChanged = Signal.new() -- (open)
Library.ThemeChanged = Signal.new() -- (key, color)
Library.ConfigLoaded = Signal.new() -- (name)
Library.Unloading = Signal.new()

--// Small helpers -------------------------------------------------------------

-- Option tables are case-insensitive: { Name = "x" } and { name = "x" } are the same.
local function Options(input, defaults)
    local cfg = {}
    if type(input) == "string" then
        cfg.name = input -- shorthand: Window:Tab("aimbot")
    elseif type(input) == "table" then
        for key, value in input do
            cfg[type(key) == "string" and string.lower(key) or key] = value
        end
    end
    if defaults then
        for key, value in defaults do
            if cfg[key] == nil then
                cfg[key] = value
            end
        end
    end
    return cfg
end

Utility.Options = Options

function Utility.Call(callback, ...)
    if type(callback) == "function" then
        task.spawn(callback, ...)
    end
end

function Utility.Connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(Library.Connections, connection)
    return connection
end

function Utility.Lerp(a, b, t)
    return a + (b - a) * t
end

function Utility.Round(value, step)
    if not step or step <= 0 then
        return value
    end
    local rounded = math.floor(value / step + 0.5) * step
    -- strip float noise such as 0.30000000000000004
    return tonumber(string.format("%.6f", rounded))
end

function Utility.ToHex(color)
    return string.format(
        "#%02x%02x%02x",
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5)
    )
end

function Utility.FromHex(hex)
    if type(hex) ~= "string" then
        return nil
    end
    local r, g, b = string.match(hex, "^#?(%x%x)(%x%x)(%x%x)")
    if not r then
        return nil
    end
    return rgb(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16))
end

function Utility.RichColor(color)
    return string.format(
        "rgb(%d,%d,%d)",
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5)
    )
end

function Utility.Escape(text)
    return (string.gsub(tostring(text), "[&<>\"']", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
        ["'"] = "&apos;",
    }))
end

-- "1" < "2" < "10" < "alpha"
function Utility.NaturalLess(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then
        return na < nb
    elseif na or nb then
        return na ~= nil
    end
    return string.lower(a) < string.lower(b)
end

--// Files -------------------------------------------------------------------

local Files = {}
Library.Files = Files

Files.Supported = Env.isfile ~= nil
    and Env.readfile ~= nil
    and Env.writefile ~= nil
    and Env.isfolder ~= nil
    and Env.makefolder ~= nil

function Files.MakeFolder(path)
    if not Files.Supported then
        return false
    end
    local current = ""
    for part in string.gmatch(path, "[^/]+") do
        current = current == "" and part or (current .. "/" .. part)
        local ok, exists = pcall(Env.isfolder, current)
        if not (ok and exists) then
            pcall(Env.makefolder, current)
        end
    end
    return true
end

function Files.Exists(path)
    if not Files.Supported then
        return false
    end
    local ok, result = pcall(Env.isfile, path)
    return ok and result == true
end

function Files.Read(path)
    if not Files.Exists(path) then
        return nil
    end
    local ok, data = pcall(Env.readfile, path)
    return ok and data or nil
end

function Files.Write(path, data)
    if not Files.Supported then
        return false
    end
    return (pcall(Env.writefile, path, data))
end

function Files.Delete(path)
    if not (Env.delfile and Files.Exists(path)) then
        return false
    end
    return (pcall(Env.delfile, path))
end

-- Returns the file names in `folder`, without `extension` when one is given.
function Files.List(folder, extension)
    local names = {}
    if not (Files.Supported and Env.listfiles) then
        return names
    end
    local ok, list = pcall(Env.listfiles, folder)
    if not ok or type(list) ~= "table" then
        return names
    end
    for _, path in list do
        local name = string.match((string.gsub(path, "\\", "/")), "([^/]+)$")
        if name then
            if not extension then
                table.insert(names, name)
            elseif string.sub(name, -#extension) == extension then
                table.insert(names, string.sub(name, 1, -#extension - 1))
            end
        end
    end
    table.sort(names, Utility.NaturalLess)
    return names
end

--// Theme -------------------------------------------------------------------

Library.Theme = {
    accent = rgb(153, 129, 188), -- fills: checkboxes, sliders, the active tab
    accent_text = rgb(201, 164, 253), -- titles and highlighted text
    text = rgb(255, 255, 255),
    text_dim = rgb(140, 140, 140),
    text_outline = rgb(0, 0, 0),
    outline = rgb(6, 6, 6), -- outer window border
    inline = rgb(29, 29, 29), -- line just inside the window border
    background = rgb(15, 15, 15),
    border = rgb(12, 12, 12), -- dark line around pages, sections and inputs
    page = rgb(20, 20, 20),
    section = rgb(25, 25, 25),
    section_inline = rgb(40, 40, 40),
    element = rgb(34, 34, 34), -- dropdowns, textboxes, unchecked boxes
    element_outline = rgb(0, 0, 0),
    button_top = rgb(38, 38, 38),
    button_bottom = rgb(32, 32, 32),
    button_outline = rgb(44, 44, 44),
    track = rgb(40, 40, 40), -- empty slider track and inactive tab bars
    dock = rgb(17, 17, 17),
    panel_inline = rgb(51, 51, 51),
}

-- Shown in this order by the theme window.
Library.ThemeOrder = {
    "accent", "accent_text", "text", "text_dim", "text_outline", "outline", "inline", "background", "border",
    "page", "section", "section_inline", "element", "element_outline", "button_top", "button_bottom",
    "button_outline", "track", "dock", "panel_inline",
}

Library.Presets = {
    rainworld = { accent = rgb(153, 129, 188), accent_text = rgb(201, 164, 253) },
    gamesense = { accent = rgb(150, 200, 60), accent_text = rgb(180, 230, 90) },
    fatality = { accent = rgb(230, 36, 110), accent_text = rgb(255, 110, 165) },
    neverlose = { accent = rgb(58, 150, 255), accent_text = rgb(130, 195, 255) },
    onetap = { accent = rgb(230, 160, 60), accent_text = rgb(255, 200, 110) },
    blood = { accent = rgb(200, 60, 60), accent_text = rgb(255, 120, 120) },
    mono = { accent = rgb(160, 160, 160), accent_text = rgb(235, 235, 235) },
}

-- Colours computed from the base theme; they follow it automatically.
local Derived = {
    accent_light = function(theme)
        return theme.accent:Lerp(WHITE, 0.12)
    end,
    track_light = function(theme)
        return theme.track:Lerp(WHITE, 0.033)
    end,
    selected = function(theme)
        return BLACK:Lerp(theme.accent, 0.545)
    end,
    list_top = function(theme)
        return BLACK:Lerp(theme.accent, 0.37)
    end,
    list_bottom = function(theme)
        return BLACK:Lerp(theme.accent, 0.05)
    end,
    editor_top = function(theme)
        return BLACK:Lerp(theme.accent, 0.25)
    end,
    editor_line = function(theme)
        return BLACK:Lerp(theme.accent, 0.41)
    end,
    gutter = function(theme)
        return theme.element:Lerp(theme.accent, 0.03)
    end,
    placeholder = function(theme)
        return theme.text_dim:Lerp(theme.accent, 0.25)
    end,
    black = function()
        return BLACK
    end,
    white = function()
        return WHITE
    end,
}

local Bindings = {} -- instance -> { property = key }
local GradientBindings = {} -- UIGradient -> { Keys = {...}, Split = number? }

function Library:GetColor(key)
    if typeof(key) == "Color3" then
        return key
    end
    local color = self.Theme[key]
    if color then
        return color
    end
    local derive = Derived[key]
    if derive then
        return derive(self.Theme)
    end
    return WHITE
end

-- Keeps `instance[property]` equal to a theme colour. Passing a Color3 instead
-- of a key sets the colour once and drops any previous binding.
function Library:Bind(instance, property, key)
    local bound = Bindings[instance]
    if typeof(key) == "Color3" then
        if bound then
            bound[property] = nil
        end
        instance[property] = key
        return
    end
    if not bound then
        bound = {}
        Bindings[instance] = bound
    end
    bound[property] = key
    instance[property] = self:GetColor(key)
end

local function GradientSequence(keys, split)
    if split then
        -- two flat tones with a hard edge, as used by bars in the design
        local a, b = Library:GetColor(keys[1]), Library:GetColor(keys[2])
        return ColorSequence.new({
            ColorSequenceKeypoint.new(0, a),
            ColorSequenceKeypoint.new(split, a),
            ColorSequenceKeypoint.new(math.min(split + 0.001, 0.999), b),
            ColorSequenceKeypoint.new(1, b),
        })
    end
    local points = {}
    for index, key in keys do
        points[index] = ColorSequenceKeypoint.new((index - 1) / (#keys - 1), Library:GetColor(key))
    end
    return ColorSequence.new(points)
end

function Library:BindGradient(gradient, keys, split)
    GradientBindings[gradient] = { Keys = keys, Split = split }
    gradient.Color = GradientSequence(keys, split)
end

function Library:RefreshTheme()
    for instance, bound in Bindings do
        for property, key in bound do
            instance[property] = self:GetColor(key)
        end
    end
    for gradient, binding in GradientBindings do
        gradient.Color = GradientSequence(binding.Keys, binding.Split)
    end
end

function Library:SetTheme(key, color)
    if self.Theme[key] == nil or typeof(color) ~= "Color3" then
        return
    end
    self.Theme[key] = color
    self:RefreshTheme()
    self.ThemeChanged:Fire(key, color)
end

-- Accepts a preset name or a table of { key = Color3 }.
function Library:ApplyTheme(theme)
    if type(theme) == "string" then
        theme = self.Presets[theme]
    end
    if type(theme) ~= "table" then
        return
    end
    for key, color in theme do
        if self.Theme[key] ~= nil and typeof(color) == "Color3" then
            self.Theme[key] = color
        end
    end
    self:RefreshTheme()
    for key, color in theme do
        self.ThemeChanged:Fire(key, color)
    end
end

-- Destroys an instance and forgets the theme and text bindings below it.
local TextBindings = {} -- instance -> role

function Utility.Destroy(instance)
    if not instance then
        return
    end
    local function forget(object)
        Bindings[object] = nil
        GradientBindings[object] = nil
        TextBindings[object] = nil
    end
    forget(instance)
    for _, descendant in instance:GetDescendants() do
        forget(descendant)
    end
    instance:Destroy()
end

--// Fonts and text roles ------------------------------------------------------

Library.FontFiles = {
    ProggyClean = "ProggyClean.ttf",
    ProggyTiny = "ProggyTiny.ttf",
    TahomaBold = "tahoma_bold.ttf",
    Tahoma = "fs-tahoma-8px.ttf",
    SmallestPixel = "smallest_pixel-7.ttf",
    Minecraftia = "Minecraftia-Regular.ttf",
    Verdana = "Verdana-Font.ttf",
}

-- Used when the executor cannot load custom fonts.
Library.FontFallbacks = {
    ProggyClean = Enum.Font.Code,
    ProggyTiny = Enum.Font.Code,
    TahomaBold = Enum.Font.SourceSansBold,
    Tahoma = Enum.Font.SourceSans,
    SmallestPixel = Enum.Font.Code,
    Minecraftia = Enum.Font.Arcade,
    Verdana = Enum.Font.SourceSans,
}

-- Every piece of text belongs to a role. Sizes follow the Figma design; set
-- the ProggyClean roles to 12 for pixel-perfect (but larger) glyphs.
Library.Text = {
    title = { Font = "ProggyClean", Size = 12 }, -- menu title
    tab = { Font = "ProggyClean", Size = 10 },
    section = { Font = "ProggyClean", Size = 8 }, -- section headers
    text = { Font = "ProggyClean", Size = 9 }, -- element labels and values
    button = { Font = "ProggyClean", Size = 10 },
    hud = { Font = "ProggyClean", Size = 10 }, -- keybind list, hitlogs, target hud, preview text
    watermark = { Font = "ProggyClean", Size = 9 }, -- watermark stats
    dock = { Font = "ProggyClean", Size = 12 },
    brand = { Font = "TahomaBold", Size = 11 }, -- name on the dock
    watermark_brand = { Font = "TahomaBold", Size = 11 },
    preview_title = { Font = "TahomaBold", Size = 16 },
    panel_title = { Font = "TahomaBold", Size = 22 }, -- configs / lua titles
    panel_text = { Font = "Tahoma", Size = 15 }, -- configs / lua lists and buttons
}

Library.Fonts = {} -- name -> Font

local function Download(url)
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(body) == "string" and #body > 0 then
        return body
    end
    if Env.request then
        local success, response = pcall(Env.request, { Url = url, Method = "GET" })
        if success and type(response) == "table" and type(response.Body) == "string" and #response.Body > 0 then
            return response.Body
        end
    end
    return nil
end

Utility.Download = Download

-- Registers a .ttf with the engine through a font-family JSON, which is how
-- executors expose custom fonts. `source` is a URL or an existing file path.
function Library:RegisterFont(name, source, weight)
    local fallback = Font.fromEnum(self.FontFallbacks[name] or Enum.Font.Code)
    if not (Files.Supported and Env.getcustomasset) then
        self.Fonts[name] = fallback
        return fallback
    end

    local ok, font = pcall(function()
        local folder = self.Folder .. "/fonts"
        Files.MakeFolder(folder)

        local path = source
        if string.match(source, "^https?://") then
            path = folder .. "/" .. name .. ".ttf"
            if not Files.Exists(path) then
                local data = Download(source)
                assert(data, "download failed")
                Files.Write(path, data)
            end
        end
        assert(Files.Exists(path), "font file missing")

        -- asset ids are per session, so the family file is rewritten every time
        local family = folder .. "/" .. name .. ".font"
        Files.Delete(family)
        Files.Write(family, HttpService:JSONEncode({
            name = name,
            faces = {
                { name = "Regular", weight = weight or 400, style = "normal", assetId = Env.getcustomasset(path) },
            },
        }))
        return Font.new(Env.getcustomasset(family), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
    end)

    self.Fonts[name] = ok and font or fallback
    return self.Fonts[name]
end

function Library:GetFont(name)
    local font = self.Fonts[name]
    if font then
        return font
    end
    local file = self.FontFiles[name]
    if file then
        return self:RegisterFont(name, self.FontSource .. file)
    end
    local ok, enum = pcall(function()
        return Enum.Font[name]
    end)
    font = Font.fromEnum(ok and enum or Enum.Font.Code)
    self.Fonts[name] = font
    return font
end

local function ApplyText(instance, role)
    local style = Library.Text[role] or Library.Text.text
    instance.FontFace = Library:GetFont(style.Font)
    instance.TextSize = style.Size
end

function Library:BindText(instance, role)
    TextBindings[instance] = role
    ApplyText(instance, role)
end

-- Library:SetText("text", { Size = 12 }) or Library:SetText("title", { Font = "TahomaBold" })
function Library:SetText(role, style)
    local current = self.Text[role]
    if not current then
        current = { Font = "ProggyClean", Size = 10 }
        self.Text[role] = current
    end
    for key, value in Options(style) do
        if key == "font" then
            current.Font = value
        elseif key == "size" then
            current.Size = value
        end
    end
    for instance, bound in TextBindings do
        if bound == role then
            ApplyText(instance, role)
        end
    end
end

--// Instances -----------------------------------------------------------------

local ColorProperties = {
    BackgroundColor3 = true,
    TextColor3 = true,
    ImageColor3 = true,
    BorderColor3 = true,
    Color = true,
    ScrollBarImageColor3 = true,
    PlaceholderColor3 = true,
}

local ClassDefaults = {
    Frame = { BorderSizePixel = 0 },
    CanvasGroup = { BorderSizePixel = 0, BackgroundTransparency = 1 },
    TextLabel = { BorderSizePixel = 0, BackgroundTransparency = 1, Text = "" },
    TextButton = { BorderSizePixel = 0, BackgroundTransparency = 1, Text = "", AutoButtonColor = false },
    TextBox = { BorderSizePixel = 0, BackgroundTransparency = 1, Text = "", ClearTextOnFocus = false },
    ImageLabel = { BorderSizePixel = 0, BackgroundTransparency = 1 },
    ImageButton = { BorderSizePixel = 0, BackgroundTransparency = 1, AutoButtonColor = false },
    ViewportFrame = { BorderSizePixel = 0, BackgroundTransparency = 1 },
    ScrollingFrame = {
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        ScrollBarThickness = 2,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    },
    UIStroke = { LineJoinMode = Enum.LineJoinMode.Miter, Thickness = 1 },
    UIListLayout = { SortOrder = Enum.SortOrder.LayoutOrder },
}

-- Creates an instance. Colour properties accept a theme key ("accent") and
-- stay bound to it; Parent is always assigned last.
function Utility.New(class, properties)
    local instance = Instance.new(class)
    local defaults = ClassDefaults[class]
    if defaults then
        for property, value in defaults do
            instance[property] = value
        end
    end
    local parent
    for property, value in properties do
        if property == "Parent" then
            parent = value
        elseif ColorProperties[property] and type(value) == "string" then
            Library:Bind(instance, property, value)
        else
            instance[property] = value
        end
    end
    if parent then
        instance.Parent = parent
    end
    return instance
end

local New = Utility.New

-- Text with the role's font and size and the design's 1px outline.
-- Extra keys: Class ("TextLabel" by default) and Stroke (false disables the outline).
function Utility.Text(role, properties)
    local class, stroke = "TextLabel", true
    local filtered = {}
    for property, value in properties do
        if property == "Class" then
            class = value
        elseif property == "Stroke" then
            stroke = value
        else
            filtered[property] = value
        end
    end
    if filtered.TextColor3 == nil then
        filtered.TextColor3 = "text"
    end
    local parent = filtered.Parent
    filtered.Parent = nil

    local label = New(class, filtered)
    Library:BindText(label, role)
    if stroke then
        New("UIStroke", { Parent = label, Color = "text_outline" })
    end
    label.Parent = parent
    return label
end

-- Nested 1px (or thicker) borders. `layers` lists { themeKey, thickness } from
-- the outside in; returns the outer frame and the innermost fill frame.
function Utility.Box(properties, layers, fill)
    local outer = New("Frame", properties)
    local current = outer
    for _, layer in layers do
        local thickness = layer[2] or 1
        Library:Bind(current, "BackgroundColor3", layer[1])
        current = New("Frame", {
            Parent = current,
            Position = fromOffset(thickness, thickness),
            Size = UDim2.new(1, -thickness * 2, 1, -thickness * 2),
        })
    end
    Library:Bind(current, "BackgroundColor3", fill)
    return outer, current
end

-- Vertical gradient between theme keys. `split` (0-1) makes it two flat tones.
function Utility.Gradient(parent, keys, split, rotation)
    local gradient = New("UIGradient", { Rotation = rotation or 90, Parent = parent })
    Library:BindGradient(gradient, keys, split)
    return gradient
end

function Utility.Tween(instance, properties, duration, style, direction)
    local tween = TweenService:Create(
        instance,
        TweenInfo.new(duration or 0.15, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
        properties
    )
    tween:Play()
    return tween
end

-- Runs `step(alpha)` every frame for `duration` seconds, alpha going 0 -> 1.
function Utility.Animate(duration, step, finished)
    local started = os.clock()
    local connection
    connection = RunService.RenderStepped:Connect(function()
        local alpha = duration <= 0 and 1 or math.clamp((os.clock() - started) / duration, 0, 1)
        step(alpha)
        if alpha >= 1 then
            connection:Disconnect()
            if finished then
                finished()
            end
        end
    end)
    table.insert(Library.Connections, connection)
    return connection
end

Utility.Easing = {
    Linear = function(t)
        return t
    end,
    Smooth = function(t)
        return 1 - (1 - t) ^ 3
    end,
    Back = function(t)
        local c = 1.70158
        return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
    end,
    Bounce = function(t)
        local n, d = 7.5625, 2.75
        if t < 1 / d then
            return n * t * t
        elseif t < 2 / d then
            t -= 1.5 / d
            return n * t * t + 0.75
        elseif t < 2.5 / d then
            t -= 2.25 / d
            return n * t * t + 0.9375
        end
        t -= 2.625 / d
        return n * t * t + 0.984375
    end,
}

--// Screen, pointer and popups ------------------------------------------------

local TouchPosition = Vector2.new(0, 0)
local LastInputWasTouch = false

local function IsPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function IsMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

Utility.IsPress = IsPress
Utility.IsMove = IsMove

-- Pointer position in the same space as AbsolutePosition (the guis ignore the
-- inset). Pass the InputObject when there is one so touches are tracked.
function Utility.Pointer(input)
    if input then
        local kind = input.UserInputType
        if kind == Enum.UserInputType.Touch then
            local inset = GuiService:GetGuiInset()
            TouchPosition = Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y)
            LastInputWasTouch = true
        elseif kind ~= Enum.UserInputType.Keyboard then
            LastInputWasTouch = false
        end
    end
    if LastInputWasTouch then
        return TouchPosition
    end
    return UserInputService:GetMouseLocation()
end

function Utility.Inside(object, point)
    local position, size = object.AbsolutePosition, object.AbsoluteSize
    return point.X >= position.X
        and point.X < position.X + size.X
        and point.Y >= position.Y
        and point.Y < position.Y + size.Y
end

function Utility.Viewport()
    local camera = Workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(1920, 1080)
end

-- Converts an absolute screen position into an offset inside the scaled roots.
function Utility.ToOffset(absolute)
    return absolute / Library.Scale
end

local function CreateScreenGui(order)
    local gui = Instance.new("ScreenGui")
    gui.Name = HttpService:GenerateGUID(false)
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = order
    if Env.protectgui then
        pcall(Env.protectgui, gui)
    end

    local parents = {}
    if Env.gethui then
        local ok, hidden = pcall(Env.gethui)
        if ok and hidden then
            table.insert(parents, hidden)
        end
    end
    local ok, core = pcall(Service, "CoreGui")
    if ok and core then
        table.insert(parents, core)
    end
    if LocalPlayer then
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            table.insert(parents, playerGui)
        end
    end
    for _, parent in parents do
        local assigned = pcall(function()
            gui.Parent = parent
        end)
        if assigned and gui.Parent == parent then
            break
        end
    end
    return gui
end

local function CreateRoot(gui)
    local root = New("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = gui })
    New("UIScale", { Scale = Library.Scale, Parent = root })
    return root
end

-- Creates the screen guis, loads fonts and hooks input. Called automatically
-- by the first component; safe to call again.
function Library:Load()
    if self.Loaded then
        return self
    end
    self.Loaded = true

    Files.MakeFolder(self.Folder .. "/configs")
    Files.MakeFolder(self.Folder .. "/scripts")

    self.Gui = CreateScreenGui(9000)
    self.OverlayGui = CreateScreenGui(9001)
    self.Root = CreateRoot(self.Gui) -- windows and hud
    self.Overlay = CreateRoot(self.OverlayGui) -- popups, always on top

    Utility.Connect(UserInputService.InputChanged, function(input)
        if IsMove(input) then
            Utility.Pointer(input)
        end
    end)

    -- clicking outside an open popup closes it
    Utility.Connect(UserInputService.InputBegan, function(input)
        if not (IsPress(input) or input.UserInputType == Enum.UserInputType.MouseButton2) then
            return
        end
        local point = Utility.Pointer(input)
        local popup = self.Popup
        if popup then
            local inside = Utility.Inside(popup.Frame, point)
            if not inside and popup.Owner then
                inside = Utility.Inside(popup.Owner, point)
            end
            if not inside then
                self:ClosePopup()
            end
        end
    end)

    -- phones have no key to press, so they get an on-screen toggle
    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
        task.defer(function()
            if not self.Unloaded and not self.Components.MobileButton then
                self:MobileButton()
            end
        end)
    end

    return self
end

function Library:OpenPopup(popup)
    if self.Popup and self.Popup ~= popup then
        self:ClosePopup()
    end
    self.Popup = popup
end

function Library:ClosePopup(popup)
    local current = self.Popup
    if current and (popup == nil or popup == current) then
        self.Popup = nil
        current.Close()
    end
end

function Library:SetScale(scale)
    scale = math.clamp(tonumber(scale) or 1, 0.5, 3)
    self.Scale = scale
    for _, root in { self.Root, self.Overlay } do
        local uiScale = root:FindFirstChildOfClass("UIScale")
        if uiScale then
            uiScale.Scale = scale
        end
        root.Size = UDim2.fromScale(1 / scale, 1 / scale)
    end
end

function Library:Toggle()
    self:SetOpen(not self.Open)
end

local TopZIndex = 10

function Utility.BringToFront(frame)
    TopZIndex += 1
    frame.ZIndex = TopZIndex
end

-- Makes `target` draggable by `handle`. Positions are plain offsets so they
-- can be saved; `changed(position)` fires when a drag ends.
function Utility.Drag(handle, target, changed, enabled)
    local dragging, origin, start = false, nil, nil

    Utility.Connect(handle.InputBegan, function(input)
        if not IsPress(input) or (enabled and not enabled()) then
            return
        end
        Library:ClosePopup()
        dragging = true
        start = Utility.Pointer(input)
        origin = Vector2.new(target.Position.X.Offset, target.Position.Y.Offset)
        Utility.BringToFront(target)
    end)

    Utility.Connect(UserInputService.InputChanged, function(input)
        if not dragging or not IsMove(input) then
            return
        end
        local delta = (Utility.Pointer(input) - start) / Library.Scale
        local limit = Utility.Viewport() / Library.Scale
        local anchor = target.AnchorPoint
        local size = target.AbsoluteSize / Library.Scale
        local scale = Vector2.new(target.Position.X.Scale * limit.X, target.Position.Y.Scale * limit.Y)
        -- keep at least a strip of the frame on screen
        local x = math.clamp(
            origin.X + delta.X,
            20 - size.X * (1 - anchor.X) - scale.X,
            limit.X - 20 + size.X * anchor.X - scale.X
        )
        local y = math.clamp(origin.Y + delta.Y, size.Y * anchor.Y - scale.Y, limit.Y - 10 + size.Y * anchor.Y - scale.Y)
        target.Position = UDim2.new(target.Position.X.Scale, x, target.Position.Y.Scale, y)
    end)

    Utility.Connect(UserInputService.InputEnded, function(input)
        if dragging and IsPress(input) then
            dragging = false
            if changed then
                changed(Vector2.new(target.Position.X.Offset, target.Position.Y.Offset))
            end
        end
    end)
end

--// Flags and configs ---------------------------------------------------------

local FlagObjects = {} -- flag -> { Get = fn, Set = fn(value), Save = bool }
local FlagListeners = {} -- flag -> { callbacks }
local FlagOrder = {}

-- Every element with a flag registers here. `object.Get` returns a JSON-safe
-- value and `object.Set` restores it.
function Library:RegisterFlag(flag, object)
    if flag == nil then
        return
    end
    if not FlagObjects[flag] then
        table.insert(FlagOrder, flag)
    end
    FlagObjects[flag] = object
end

function Library:SetFlag(flag, value)
    if flag == nil then
        return
    end
    self.Flags[flag] = value
    local listeners = FlagListeners[flag]
    if listeners then
        for _, callback in table.clone(listeners) do
            task.spawn(callback, value)
        end
    end
    self.Changed:Fire(flag, value)
end

-- Calls `callback(value)` whenever the flag changes; returns a disconnect function.
function Library:OnChanged(flag, callback)
    local listeners = FlagListeners[flag]
    if not listeners then
        listeners = {}
        FlagListeners[flag] = listeners
    end
    table.insert(listeners, callback)
    return function()
        local index = table.find(listeners, callback)
        if index then
            table.remove(listeners, index)
        end
    end
end

-- Flags that describe the interface itself: window positions and visibility,
-- theme colours and the theme window's settings.
local function IsInterfaceFlag(flag)
    if type(flag) ~= "string" then
        return false
    end
    for _, prefix in { "pos_", "show_", "theme_", "ui_" } do
        if string.sub(flag, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

-- Library.SaveInterface = false keeps layout and theme out of configs.
local function Persisted(flag, object)
    return object ~= nil and object.Save ~= false and (Library.SaveInterface ~= false or not IsInterfaceFlag(flag))
end

function Library:GetConfigTable()
    local data = {}
    for _, flag in FlagOrder do
        local object = FlagObjects[flag]
        if Persisted(flag, object) then
            local ok, value = pcall(object.Get)
            if ok and value ~= nil then
                data[flag] = value
            end
        end
    end
    return data
end

function Library:GetConfig()
    return HttpService:JSONEncode({ name = self.Name, version = 1, flags = self:GetConfigTable() })
end

-- Loads a config from a JSON string or an already decoded table.
function Library:LoadConfig(config)
    if type(config) == "string" then
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(config)
        end)
        if not ok then
            return false
        end
        config = decoded
    end
    if type(config) ~= "table" then
        return false
    end
    local flags = type(config.flags) == "table" and config.flags or config
    for _, flag in FlagOrder do
        local object, value = FlagObjects[flag], flags[flag]
        if value ~= nil and Persisted(flag, object) then
            local ok, message = pcall(object.Set, value)
            if not ok then
                warn(string.format("[%s] could not restore '%s': %s", self.Name, tostring(flag), tostring(message)))
            end
        end
    end
    return true
end

-- Configs live in <Folder>/configs/<name>.cfg. Without a filesystem they are
-- kept in memory for the session so the config window still works.
local MemoryConfigs = {}

local function ConfigPath(name)
    return Library.Folder .. "/configs/" .. name .. ".cfg"
end

function Library:ListConfigs()
    if Files.Supported then
        return Files.List(self.Folder .. "/configs", ".cfg")
    end
    local names = {}
    for name in MemoryConfigs do
        table.insert(names, name)
    end
    table.sort(names, Utility.NaturalLess)
    return names
end

-- Without a name, saves under the next free number ("1", "2", ...).
function Library:SaveConfig(name)
    if name == nil or name == "" then
        local taken = {}
        for _, existing in self:ListConfigs() do
            taken[existing] = true
        end
        local index = 1
        while taken[tostring(index)] do
            index += 1
        end
        name = tostring(index)
    end
    name = string.gsub(tostring(name), "[^%w%-_ %.]", "")
    local config = self:GetConfig()
    if Files.Supported then
        Files.MakeFolder(self.Folder .. "/configs")
        Files.Write(ConfigPath(name), config)
    else
        MemoryConfigs[name] = config
    end
    return name
end

function Library:LoadConfigFile(name)
    local config
    if Files.Supported then
        config = Files.Read(ConfigPath(name))
    else
        config = MemoryConfigs[name]
    end
    if not config or not self:LoadConfig(config) then
        return false
    end
    self.ConfigLoaded:Fire(name)
    return true
end

function Library:DeleteConfig(name)
    if Files.Supported then
        Files.Delete(ConfigPath(name))
    else
        MemoryConfigs[name] = nil
    end
    if self:GetAutoload() == name then
        self:SetAutoload(nil)
    end
end

function Library:SetAutoload(name)
    local path = self.Folder .. "/autoload.txt"
    if name then
        Files.Write(path, name)
    else
        Files.Delete(path)
    end
end

function Library:GetAutoload()
    local name = Files.Read(self.Folder .. "/autoload.txt")
    if name and name ~= "" then
        return name
    end
    return nil
end

function Library:LoadAutoload()
    local name = self:GetAutoload()
    if name then
        return self:LoadConfigFile(name)
    end
    return false
end

--// Panels --------------------------------------------------------------------
-- A panel is anything that sits directly on the screen: windows, the dock and
-- the hud pieces. Hud panels stay visible while the menu is closed.

local Panel = {}
Panel.__index = Panel

local function ToVector2(value, fallback)
    if typeof(value) == "Vector2" then
        return value
    elseif typeof(value) == "UDim2" then
        return Vector2.new(value.X.Offset, value.Y.Offset)
    elseif type(value) == "table" then
        return Vector2.new(value[1] or value.X or 0, value[2] or value.Y or 0)
    end
    return fallback
end

Utility.ToVector2 = ToVector2

function Panel:Refresh()
    self.Frame.Visible = self.Enabled and (self.Hud or Library.Open)
end

function Panel:SetVisible(visible)
    visible = visible == true
    if self.Enabled == visible then
        return
    end
    self.Enabled = visible
    self:Refresh()
    self.VisibilityChanged:Fire(visible)
end

function Panel:Toggle()
    self:SetVisible(not self.Enabled)
end

function Panel:IsVisible()
    return self.Enabled
end

function Panel:SetPosition(position)
    position = ToVector2(position)
    if position then
        local current = self.Frame.Position
        self.Frame.Position = UDim2.new(current.X.Scale, position.X, current.Y.Scale, position.Y)
    end
end

function Panel:GetPosition()
    local position = self.Frame.Position
    return Vector2.new(position.X.Offset, position.Y.Offset)
end

-- Wires the shared panel behaviour onto `panel` (which already has a Frame).
-- cfg.id names the config flags that remember visibility and position.
local function SetupPanel(panel, cfg, hud)
    panel.Id = cfg.id
    panel.Enabled = cfg.visible ~= false
    panel.Hud = hud == true
    panel.VisibilityChanged = Signal.new()

    if cfg.id then
        Library:RegisterFlag("show_" .. cfg.id, {
            Get = function()
                return panel.Enabled
            end,
            Set = function(value)
                panel:SetVisible(value == true)
            end,
        })
        Library:RegisterFlag("pos_" .. cfg.id, {
            Get = function()
                local position = panel:GetPosition()
                return { position.X, position.Y }
            end,
            Set = function(value)
                panel:SetPosition(value)
            end,
        })
    end

    table.insert(Library.Panels, panel)
    panel:Refresh()

    -- the default positions come from a 1584x891 design; pull anything that
    -- would start off a smaller screen back into view
    task.defer(function()
        local frame = panel.Frame
        local position = frame.Position
        if Library.Unloaded or position.X.Scale ~= 0 or position.Y.Scale ~= 0 then
            return
        end
        local view = Utility.Viewport() / Library.Scale
        local size = frame.AbsoluteSize / Library.Scale
        local x = math.clamp(position.X.Offset, 0, math.max(0, view.X - size.X))
        local y = math.clamp(position.Y.Offset, 0, math.max(0, view.Y - size.Y))
        if x ~= position.X.Offset or y ~= position.Y.Offset then
            panel:SetPosition(Vector2.new(x, y))
        end
    end)
    return panel
end

function Library:SetOpen(open)
    open = open == true
    if self.Open == open then
        return
    end
    self.Open = open
    self:ClosePopup()
    for _, panel in self.Panels do
        panel:Refresh()
    end
    self.OpenChanged:Fire(open)
end

--// Window --------------------------------------------------------------------

local Window = setmetatable({}, { __index = Panel })
Window.__index = Window

local Tab = {}
Tab.__index = Tab

local Section = {}
Section.__index = Section

local TAB_GAP, COLUMN_GAP, PAGE_PADDING = 4, 7, 5

-- Splits `total` pixels into `count` integer widths separated by `gap`.
local function Distribute(total, count, gap)
    local available = total - gap * (count - 1)
    local base = math.floor(available / count)
    local extra = available - base * count
    local sizes = {}
    for index = 1, count do
        sizes[index] = base + (index <= extra and 1 or 0)
    end
    return sizes
end

function Library:Window(properties)
    self:Load()
    local cfg = Options(properties, {
        name = self.Name,
        size = Vector2.new(387, 554),
        position = Vector2.new(261, 112),
        columns = 2,
    })
    cfg.id = cfg.id or ("window_" .. string.lower(cfg.name))

    local size = ToVector2(cfg.size, Vector2.new(387, 554))
    local position = ToVector2(cfg.position, Vector2.new(261, 112))

    local outline, background = Utility.Box({
        Name = "Window",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(size.X, size.Y),
        Active = true,
    }, { { "outline", 2 }, { "inline", 1 } }, "background")

    local window = setmetatable({
        Name = cfg.name,
        Frame = outline,
        Size = size,
        ColumnCount = cfg.columns,
        Tabs = {},
        Current = nil,
    }, Window)

    window.Title = Utility.Text("title", {
        Parent = background,
        Position = fromOffset(0, 7),
        Size = UDim2.new(1, 0, 0, 20),
        Text = cfg.name,
        TextColor3 = "accent_text",
    })

    local handle = New("Frame", {
        Parent = background,
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        Active = true,
    })
    Utility.Drag(handle, outline)

    window.TabHolder = New("Frame", {
        Parent = background,
        Position = fromOffset(3, 30),
        Size = UDim2.new(1, -6, 0, 24),
        BackgroundTransparency = 1,
    })

    local _, page = Utility.Box({
        Parent = background,
        Position = fromOffset(2, 62),
        Size = UDim2.new(1, -4, 1, -64),
    }, { { "border" } }, "page")
    window.Page = page

    SetupPanel(window, cfg)
    if not self.Components.Menu then
        self.Components.Menu = window -- the first window is the one scripts add tabs to
    end
    return window
end

-- Pixel sizes derived from the window size, mirroring the design's insets.
function Window:Metrics()
    local inner = self.Size - Vector2.new(6, 6) -- 2px outline + 1px inline per side
    local page = Vector2.new(inner.X - 6, inner.Y - 66) -- inside the page border
    return {
        TabWidth = inner.X - 6,
        ColumnArea = Vector2.new(page.X - PAGE_PADDING * 2, page.Y - PAGE_PADDING * 2),
    }
end

function Window:Layout()
    local metrics = self:Metrics()

    local count = #self.Tabs
    if count > 0 then
        local widths, x = Distribute(metrics.TabWidth, count, TAB_GAP), 0
        for index, tab in self.Tabs do
            tab.Button.Position = fromOffset(x, 0)
            tab.Button.Size = fromOffset(widths[index], 24)
            x += widths[index] + TAB_GAP
        end
    end

    for _, tab in self.Tabs do
        local widths, x = Distribute(metrics.ColumnArea.X, #tab.Columns, COLUMN_GAP), PAGE_PADDING
        for index, column in tab.Columns do
            column.Frame.Position = fromOffset(x, PAGE_PADDING)
            column.Frame.Size = fromOffset(widths[index], metrics.ColumnArea.Y)
            column.Height = metrics.ColumnArea.Y
            x += widths[index] + COLUMN_GAP
            tab:LayoutColumn(column)
        end
    end
end

function Window:SetSize(size)
    size = ToVector2(size)
    if size then
        self.Size = size
        self.Frame.Size = fromOffset(size.X, size.Y)
        self:Layout()
    end
end

function Window:SetName(name)
    self.Name = name
    self.Title.Text = name
end

function Window:SelectTab(tab)
    if type(tab) == "string" then
        for _, candidate in self.Tabs do
            if candidate.Name == tab then
                tab = candidate
                break
            end
        end
    end
    if type(tab) ~= "table" or self.Current == tab then
        return
    end
    Library:ClosePopup()
    self.Current = tab
    for _, other in self.Tabs do
        local active = other == tab
        other.Page.Visible = active
        Library:BindGradient(other.BarGradient, active and { "accent_light", "accent" } or { "track_light", "track" }, 0.5)
    end
end

function Window:Tab(properties)
    local cfg = Options(properties, { name = "tab" })
    local window = self

    local tab = setmetatable({
        Window = window,
        Name = cfg.name,
        Columns = {},
    }, Tab)

    tab.Button = New("TextButton", { Parent = window.TabHolder })
    tab.Label = Utility.Text("tab", {
        Parent = tab.Button,
        Size = UDim2.new(1, 0, 0, 19),
        Text = cfg.name,
    })
    local bar = New("Frame", {
        Parent = tab.Button,
        Position = fromOffset(0, 20),
        Size = UDim2.new(1, 0, 0, 4),
        BackgroundColor3 = WHITE,
    })
    tab.BarGradient = Utility.Gradient(bar, { "track_light", "track" }, 0.5)

    tab.Page = New("Frame", {
        Parent = window.Page,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
    })

    for index = 1, math.max(1, cfg.columns or window.ColumnCount) do
        tab.Columns[index] = {
            Frame = New("Frame", { Parent = tab.Page, BackgroundTransparency = 1 }),
            Sections = {},
            Height = 0,
        }
    end

    Utility.Connect(tab.Button.MouseButton1Click, function()
        window:SelectTab(tab)
    end)

    table.insert(window.Tabs, tab)
    window:Layout()
    if not window.Current then
        window:SelectTab(tab)
    end
    return tab
end

function Tab:Select()
    self.Window:SelectTab(self)
end

-- Sections with a number Height keep it; the others share what is left.
function Tab:LayoutColumn(column)
    local visible, fixed, fills = {}, 0, 0
    for _, section in column.Sections do
        if section.Frame.Visible then
            table.insert(visible, section)
            if type(section.Height) == "number" then
                fixed += section.Height
            else
                fills += 1
            end
        end
    end
    if #visible == 0 then
        return
    end

    local free = column.Height - fixed - COLUMN_GAP * (#visible - 1)
    local each = fills > 0 and math.max(20, math.floor(free / fills)) or 0
    local leftover = fills > 0 and math.max(0, free - each * fills) or 0
    local y = 0
    for _, section in visible do
        local height = section.Height
        if type(height) ~= "number" then
            height = each
            fills -= 1
            if fills == 0 then
                height += leftover
            end
        end
        section.Frame.Position = fromOffset(0, y)
        section.Frame.Size = UDim2.new(1, 0, 0, height)
        y += height + COLUMN_GAP
    end
end

function Tab:Section(properties)
    local cfg = Options(properties, { name = "section", side = "left" })
    local side = string.lower(tostring(cfg.side))
    local index = cfg.column or (side == "right" and #self.Columns) or (side == "middle" and 2) or 1
    local column = self.Columns[math.clamp(index, 1, #self.Columns)]

    local section = setmetatable({
        Tab = self,
        Window = self.Window,
        Column = column,
        Name = cfg.name,
        Height = cfg.height, -- number: fixed, "auto": fit content, nil: fill
        Order = 0,
    }, Section)

    local outer, fill = Utility.Box({ Parent = column.Frame }, { { "border" }, { "section_inline" } }, "section")
    section.Frame = outer

    section.Title = Utility.Text("section", {
        Parent = outer,
        Position = fromOffset(6, -3),
        Size = fromOffset(0, 10),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = cfg.name,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 2,
    })

    section.Content = New("ScrollingFrame", {
        Parent = fill,
        Size = UDim2.fromScale(1, 1),
        ScrollBarImageColor3 = "accent",
    })
    New("UIPadding", {
        Parent = section.Content,
        PaddingTop = UDim.new(0, 7),
        PaddingBottom = UDim.new(0, 5),
        PaddingLeft = UDim.new(0, 2),
        PaddingRight = UDim.new(0, 2),
    })
    New("UIListLayout", { Parent = section.Content, Padding = UDim.new(0, 5) })

    -- Height = "auto" fits the section to its rows as they are added
    section.Auto = cfg.height == "auto"
    section.ContentHeight = 0
    if section.Auto then
        section.Height = 16
    end

    table.insert(column.Sections, section)
    self:LayoutColumn(column)
    return section
end

function Section:SetVisible(visible)
    self.Frame.Visible = visible == true
    self.Tab:LayoutColumn(self.Column)
end

function Section:SetName(name)
    self.Name = name
    self.Title.Text = name
end

-- A full-width row in the section's list.
function Section:Row(height)
    self.Order += 1
    self.ContentHeight += height + (self.Order > 1 and 5 or 0)
    if self.Auto then
        self.Height = self.ContentHeight + 16 -- list padding + borders
        self.Tab:LayoutColumn(self.Column)
    end
    return New("Frame", {
        Parent = self.Content,
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        LayoutOrder = self.Order,
    })
end

--// Elements ------------------------------------------------------------------

local Left, Right = Enum.TextXAlignment.Left, Enum.TextXAlignment.Right

local function Finish(element, cfg, frame)
    element.Frame = frame
    element.Flag = cfg.flag
    element.Changed = element.Changed or Signal.new()

    function element:SetVisible(visible)
        frame.Visible = visible == true
    end

    function element:OnChanged(callback)
        return self.Changed:Connect(callback)
    end

    if cfg.flag ~= nil then
        Library.Options[cfg.flag] = element
    end
    if cfg.visible == false then
        frame.Visible = false
    end
    return element
end

-- A plus/minus glyph drawn with frames so it stays crisp at any text size.
local function Glyph(parent, position, size, plus)
    local half = math.floor(size / 2)
    local holder = New("Frame", {
        Parent = parent,
        Position = position,
        Size = fromOffset(size, size),
        BackgroundTransparency = 1,
    })
    New("Frame", { Parent = holder, Position = fromOffset(0, half), Size = fromOffset(size, 1), BackgroundColor3 = "text" })
    local vertical = New("Frame", {
        Parent = holder,
        Position = fromOffset(half, 0),
        Size = fromOffset(1, size),
        BackgroundColor3 = "text",
        Visible = plus,
    })
    return holder, vertical
end

--// Keys ------------------------------------------------------------------------

local KeyNames = {
    LeftShift = "lshift", RightShift = "rshift", LeftControl = "lctrl", RightControl = "rctrl",
    LeftAlt = "lalt", RightAlt = "ralt", CapsLock = "caps", Backspace = "back", Return = "enter",
    Escape = "esc", Insert = "ins", Delete = "del", PageUp = "pgup", PageDown = "pgdn",
    MouseButton1 = "mb1", MouseButton2 = "mb2", MouseButton3 = "mb3",
    One = "1", Two = "2", Three = "3", Four = "4", Five = "5",
    Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
}

function Utility.KeyName(key)
    if not key then
        return "none"
    end
    local name = typeof(key) == "EnumItem" and key.Name or tostring(key)
    return KeyNames[name] or string.lower(name)
end

function Utility.ParseKey(name)
    if typeof(name) == "EnumItem" then
        return name
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local ok, key = pcall(function()
        return Enum.KeyCode[name]
    end)
    if ok and key then
        return key
    end
    ok, key = pcall(function()
        return Enum.UserInputType[name]
    end)
    return ok and key or nil
end

local Modes = { toggle = "Toggle", hold = "Hold", always = "Always" }

Library.KeybindsChanged = Signal.new()

-- Small list popup used by keybind modes.
local function ChoicePopup(owner, choices, current, picked)
    local popup, fill = Utility.Box({
        Parent = Library.Overlay,
        ZIndex = 60,
        Active = true,
    }, { { "border" } }, "element")
    New("UIListLayout", { Parent = fill })

    local width = 44
    for index, choice in choices do
        local row = Utility.Text("text", {
            Class = "TextButton",
            Parent = fill,
            Size = UDim2.new(1, 0, 0, 13),
            Text = string.lower(choice),
            TextColor3 = choice == current and "accent_text" or "text",
            LayoutOrder = index,
        })
        width = math.max(width, #choice * 6 + 10)
        Utility.Connect(row.MouseButton1Click, function()
            Library:ClosePopup()
            picked(choice)
        end)
    end

    local origin = Utility.ToOffset(owner.AbsolutePosition)
    popup.Size = fromOffset(width, #choices * 13 + 2)
    popup.Position = fromOffset(origin.X, origin.Y + owner.AbsoluteSize.Y / Library.Scale + 2)

    Library:OpenPopup({
        Frame = popup,
        Owner = owner,
        Close = function()
            Utility.Destroy(popup)
        end,
    })
end

local function CreateKeybind(holder, properties, name, order, owner)
    local cfg = Options(properties, { name = name, mode = "Toggle" })
    local keybind = {
        Class = "Keybind",
        Name = cfg.name,
        Key = nil,
        Mode = Modes[string.lower(tostring(cfg.mode))] or "Toggle",
        Active = false,
        Owner = owner, -- the toggle this keybind is attached to, if any
        Hidden = cfg.hidden == true, -- keep out of the keybind list
        Changed = Signal.new(),
    }
    -- Library.Flags[flag] is this table, updated in place.
    local state = { Key = nil, Mode = keybind.Mode, Active = false }

    local button = Utility.Text("text", {
        Class = "TextButton",
        Parent = holder,
        Size = fromOffset(0, 10),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = "[none]",
        TextColor3 = "text_dim",
        LayoutOrder = order,
    })
    keybind.Button = button

    local function publish()
        state.Key, state.Mode, state.Active = keybind.Key, keybind.Mode, keybind.Active
        Library:SetFlag(cfg.flag, state)
        Library.KeybindsChanged:Fire(keybind)
    end

    function keybind:SetActive(active, silent)
        if self.Mode == "Always" then
            active = true
        end
        active = active == true
        if self.Active == active then
            return
        end
        self.Active = active
        publish()
        self.Changed:Fire(active)
        if cfg.sync and owner and owner.Set then
            owner:Set(active)
        end
        if not silent then
            Utility.Call(cfg.callback, active)
        end
    end

    function keybind:SetKey(key)
        self.Key = Utility.ParseKey(key)
        button.Text = "[" .. Utility.KeyName(self.Key) .. "]"
        publish()
        Utility.Call(cfg.keychanged, self.Key)
    end

    function keybind:SetMode(mode)
        self.Mode = Modes[string.lower(tostring(mode))] or "Toggle"
        if self.Mode == "Always" then
            self:SetActive(true)
        elseif self.Active then
            self:SetActive(false)
        else
            publish()
        end
    end

    function keybind:Set(value)
        if type(value) == "table" then
            self.Mode = Modes[string.lower(tostring(value.mode or value.Mode or self.Mode))] or self.Mode
            self:SetKey(value.key or value.Key)
            self:SetActive(self.Mode == "Always")
        else
            self:SetKey(value)
        end
    end

    function keybind:Get()
        return state
    end

    -- True when the bound feature should run right now.
    function keybind:IsActive()
        if owner and owner.Class == "Toggle" and not owner.Value then
            return false
        end
        return self.Active
    end

    function keybind:Listen()
        Library:ClosePopup()
        Library.Listening = self
        button.Text = "[...]"
        Library:Bind(button, "TextColor3", "accent_text")
        if self.OnListen then
            self.OnListen(true)
        end
    end

    function keybind:StopListening(key, cancelled)
        Library:Bind(button, "TextColor3", "text_dim")
        if cancelled then
            button.Text = "[" .. Utility.KeyName(self.Key) .. "]"
        else
            self:SetKey(key)
        end
        if self.OnListen then
            self.OnListen(false)
        end
    end

    -- Display = false keeps the key out of the row (see AttachAddons)
    button.Visible = cfg.display ~= false

    Utility.Connect(button.MouseButton1Click, function()
        if Library.Listening == keybind then
            return
        end
        keybind:Listen()
    end)

    if cfg.modes ~= false then
        Utility.Connect(button.MouseButton2Click, function()
            ChoicePopup(button, { "Toggle", "Hold", "Always" }, keybind.Mode, function(mode)
                keybind:SetMode(mode)
            end)
        end)
    end

    keybind.Frame = button
    keybind.Flag = cfg.flag
    if cfg.flag ~= nil then
        Library.Options[cfg.flag] = keybind
    end
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return { key = keybind.Key and keybind.Key.Name or "", mode = keybind.Mode }
        end,
        Set = function(value)
            keybind:Set(value)
        end,
    })

    table.insert(Library.Keybinds, keybind)
    keybind:SetKey(cfg.default or cfg.key)
    if keybind.Mode == "Always" then
        keybind:SetActive(true, true)
    end
    return keybind
end

local function Matches(key, input)
    return key ~= nil and (input.KeyCode == key or input.UserInputType == key)
end

Utility.Connect(UserInputService.InputBegan, function(input)
    local listening = Library.Listening
    if listening then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            Library.Listening = nil
            local clear = input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace
            listening:StopListening(not clear and input.KeyCode or nil, false)
        elseif
            input.UserInputType == Enum.UserInputType.MouseButton2
            or input.UserInputType == Enum.UserInputType.MouseButton3
        then
            Library.Listening = nil
            listening:StopListening(input.UserInputType, false)
        elseif IsPress(input) then
            Library.Listening = nil
            listening:StopListening(nil, true)
        end
        return
    end

    if UserInputService:GetFocusedTextBox() then
        return
    end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Library.ToggleKey then
        Library:SetOpen(not Library.Open)
    end
    for _, keybind in Library.Keybinds do
        if Matches(keybind.Key, input) then
            if keybind.Mode == "Toggle" then
                keybind:SetActive(not keybind.Active)
            elseif keybind.Mode == "Hold" then
                keybind:SetActive(true)
            end
        end
    end
end)

Utility.Connect(UserInputService.InputEnded, function(input)
    for _, keybind in Library.Keybinds do
        if keybind.Mode == "Hold" and Matches(keybind.Key, input) then
            keybind:SetActive(false)
        end
    end
end)

--// Colour picker ---------------------------------------------------------------

local ColorPopup = { Hue = 0, Saturation = 1, Value = 1, Current = nil }

local Rainbow = ColorSequence.new({
    ColorSequenceKeypoint.new(0, rgb(255, 0, 0)),
    ColorSequenceKeypoint.new(1 / 6, rgb(255, 255, 0)),
    ColorSequenceKeypoint.new(2 / 6, rgb(0, 255, 0)),
    ColorSequenceKeypoint.new(3 / 6, rgb(0, 255, 255)),
    ColorSequenceKeypoint.new(4 / 6, rgb(0, 0, 255)),
    ColorSequenceKeypoint.new(5 / 6, rgb(255, 0, 255)),
    ColorSequenceKeypoint.new(1, rgb(255, 0, 0)),
})

function ColorPopup:Build()
    if self.Frame then
        return
    end
    local frame, inner = Utility.Box({
        Parent = Library.Overlay,
        Size = fromOffset(130, 150),
        Visible = false,
        ZIndex = 50,
        Active = true,
    }, { { "element_outline" } }, "background")
    self.Frame = frame

    -- hue strip
    local hueOuter, hue = Utility.Box({
        Parent = inner,
        Position = fromOffset(3, 3),
        Size = fromOffset(122, 17),
        Active = true,
    }, { { "element_outline" } }, "white")
    New("UIGradient", { Color = Rainbow, Parent = hue })
    self.HueBar = hue
    self.HueLine = New("Frame", {
        Parent = hue,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0, 0, 0, -1),
        Size = UDim2.new(0, 1, 1, 2),
        BackgroundColor3 = WHITE,
        ZIndex = 2,
    })

    -- saturation / value square: hue colour, white fading right, black fading up
    local squareOuter, square = Utility.Box({
        Parent = inner,
        Position = fromOffset(3, 23),
        Size = fromOffset(122, 122),
        Active = true,
    }, { { "element_outline" } }, "white")
    self.Square = square
    Library:Bind(square, "BackgroundColor3", WHITE) -- recoloured by hand, not by the theme
    local white = New("Frame", { Parent = square, Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE })
    New("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = white })
    local black = New("Frame", { Parent = square, Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, ZIndex = 2 })
    New("UIGradient", { Transparency = NumberSequence.new(1, 0), Rotation = 90, Parent = black })
    self.Cursor = New("Frame", {
        Parent = square,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = fromOffset(3, 3),
        BackgroundColor3 = WHITE,
        ZIndex = 3,
    })
    New("UIStroke", { Parent = self.Cursor, Color = BLACK })

    -- optional transparency strip
    local alphaOuter, alpha = Utility.Box({
        Parent = inner,
        Position = fromOffset(3, 148),
        Size = fromOffset(122, 17),
        Active = true,
        Visible = false,
    }, { { "element_outline" } }, "element")
    self.AlphaOuter = alphaOuter
    self.AlphaFill = New("Frame", { Parent = alpha, Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE })
    New("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = self.AlphaFill })
    self.AlphaBar = alpha
    self.AlphaLine = New("Frame", {
        Parent = alpha,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0, 0, 0, -1),
        Size = UDim2.new(0, 1, 1, 2),
        BackgroundColor3 = WHITE,
        ZIndex = 2,
    })

    local dragging
    local function update(input)
        local picker = self.Current
        if not picker or not dragging then
            return
        end
        local point = Utility.Pointer(input)
        local bar = dragging == "hue" and self.HueBar or dragging == "alpha" and self.AlphaBar or self.Square
        local x = math.clamp((point.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local y = math.clamp((point.Y - bar.AbsolutePosition.Y) / bar.AbsoluteSize.Y, 0, 1)
        local transparency = picker.Transparency
        if dragging == "hue" then
            self.Hue = x
        elseif dragging == "alpha" then
            transparency = x
        else
            self.Saturation, self.Value = x, 1 - y
        end
        self.Applying = true
        picker:Set(Color3.fromHSV(self.Hue, self.Saturation, self.Value), transparency)
        self.Applying = false
        self:Render()
    end

    for name, target in { hue = hueOuter, square = squareOuter, alpha = alphaOuter } do
        Utility.Connect(target.InputBegan, function(input)
            if IsPress(input) then
                dragging = name
                update(input)
            end
        end)
    end
    Utility.Connect(UserInputService.InputChanged, function(input)
        if dragging and IsMove(input) then
            update(input)
        end
    end)
    Utility.Connect(UserInputService.InputEnded, function(input)
        if IsPress(input) then
            dragging = nil
        end
    end)
end

function ColorPopup:Render()
    local picker = self.Current
    if not picker then
        return
    end
    self.HueLine.Position = UDim2.new(self.Hue, 0, 0, -1)
    self.Square.BackgroundColor3 = Color3.fromHSV(self.Hue, 1, 1)
    self.Cursor.Position = UDim2.fromScale(self.Saturation, 1 - self.Value)
    self.AlphaFill.BackgroundColor3 = picker.Value
    self.AlphaLine.Position = UDim2.new(picker.Transparency, 0, 0, -1)
end

-- Re-reads the picker's colour (used when it changes from code while open).
function ColorPopup:Sync()
    local picker = self.Current
    if not picker or self.Applying then
        return
    end
    local hue, saturation, value = picker.Value:ToHSV()
    -- hue is undefined for greys; keep the strip where the user left it
    if saturation > 0 and value > 0 then
        self.Hue = hue
    end
    self.Saturation, self.Value = saturation, value
    self:Render()
end

function ColorPopup:Open(picker, anchor)
    self:Build()
    if self.Current == picker and self.Frame.Visible then
        Library:ClosePopup()
        return
    end
    Library:ClosePopup()
    self.Current = picker
    self.AlphaOuter.Visible = picker.HasTransparency
    self.Frame.Size = fromOffset(130, picker.HasTransparency and 170 or 150)

    -- docks to the left of the owning window like in the design, else to the right
    local reference = picker.Window and picker.Window.Frame or anchor
    local origin = Utility.ToOffset(reference.AbsolutePosition)
    local width = reference.AbsoluteSize.X / Library.Scale
    local x = origin.X - 138
    if x < 0 then
        x = origin.X + width + 8
    end
    self.Frame.Position = fromOffset(x, origin.Y)
    self.Frame.Visible = true
    self:Sync()

    Library:OpenPopup({
        Frame = self.Frame,
        Owner = anchor,
        Close = function()
            self.Frame.Visible = false
            self.Current = nil
        end,
    })
end

local function CreateColorpicker(holder, properties, name, order, window)
    local cfg = Options(properties, { name = name, default = Library.Theme.accent })
    local picker = {
        Class = "Colorpicker",
        Name = cfg.name,
        Value = cfg.default,
        Transparency = cfg.transparency or 0,
        HasTransparency = cfg.transparency ~= nil,
        Window = window,
        Changed = Signal.new(),
    }
    -- Library.Flags[flag] is this table, updated in place.
    local state = { Color = picker.Value, Transparency = picker.Transparency }

    local swatch, fill = Utility.Box({
        Parent = holder,
        Size = fromOffset(15, 10),
        LayoutOrder = order,
    }, { { "element_outline" } }, "white")
    local button = New("TextButton", { Parent = swatch, Size = UDim2.fromScale(1, 1), ZIndex = 2 })

    function picker:Set(color, transparency, silent)
        if typeof(color) ~= "Color3" then
            return
        end
        self.Value = color
        if transparency ~= nil and self.HasTransparency then
            self.Transparency = math.clamp(transparency, 0, 1)
        end
        Library:Bind(fill, "BackgroundColor3", color) -- a Color3 replaces the theme binding
        state.Color, state.Transparency = color, self.Transparency
        Library:SetFlag(cfg.flag, state)
        self.Changed:Fire(color, self.Transparency)
        if not silent then
            Utility.Call(cfg.callback, color, self.Transparency)
        end
        if ColorPopup.Current == self then
            ColorPopup:Sync()
        end
    end

    function picker:Get()
        return self.Value, self.Transparency
    end

    function picker:SetVisible(visible)
        swatch.Visible = visible == true
    end

    function picker:OnChanged(callback)
        return self.Changed:Connect(callback)
    end

    Utility.Connect(button.MouseButton1Click, function()
        ColorPopup:Open(picker, swatch)
    end)

    picker.Frame = swatch
    picker.Flag = cfg.flag
    if cfg.flag ~= nil then
        Library.Options[cfg.flag] = picker
    end
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return { color = Utility.ToHex(picker.Value), transparency = picker.Transparency }
        end,
        Set = function(value)
            if type(value) == "table" then
                picker:Set(Utility.FromHex(value.color) or picker.Value, value.transparency)
            else
                picker:Set(Utility.FromHex(value) or picker.Value)
            end
        end,
    })
    picker:Set(cfg.default, picker.Transparency)
    return picker
end

-- Toggles and labels can carry colour pickers and a keybind on their right side.
-- `clicker` is the row's button, when it has one.
local function AttachAddons(element, row, section, clicker)
    local holder = New("Frame", {
        Parent = row,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -1, 0, 0),
        Size = fromOffset(0, 10),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        ZIndex = 2,
    })
    New("UIListLayout", {
        Parent = holder,
        FillDirection = Enum.FillDirection.Horizontal,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding = UDim.new(0, 2),
    })
    local order = 0

    function element:Colorpicker(properties)
        order += 1
        return CreateColorpicker(holder, properties, element.Name, order, section.Window)
    end

    function element:Keybind(properties)
        order += 1
        local keybind = CreateKeybind(holder, properties, element.Name, order, element)
        if not keybind.Button.Visible and clicker then
            -- hidden key text: right-click the row to bind, the label lights up meanwhile
            keybind.OnListen = function(listening)
                Library:Bind(element.Label, "TextColor3", listening and "accent_text" or "text")
            end
            Utility.Connect(clicker.MouseButton2Click, function()
                keybind:Listen()
            end)
        end
        return keybind
    end
end

--// Toggle ----------------------------------------------------------------------

function Section:Toggle(properties)
    local cfg = Options(properties, { name = "toggle", default = false })
    local toggle = { Class = "Toggle", Name = cfg.name, Value = false }

    local row = self:Row(10)
    local button = New("TextButton", { Parent = row, Size = UDim2.fromScale(1, 1) })
    local _, check = Utility.Box({
        Parent = row,
        Position = fromOffset(1, 0),
        Size = fromOffset(10, 10),
    }, { { "element_outline" } }, "element")
    toggle.Label = Utility.Text("text", {
        Parent = row,
        Position = fromOffset(16, 1),
        Size = UDim2.new(1, -16, 1, 0),
        Text = cfg.name,
        TextXAlignment = Left,
    })

    function toggle:Set(value, silent)
        value = value == true
        self.Value = value
        Library:Bind(check, "BackgroundColor3", value and "accent" or "element")
        Library:SetFlag(cfg.flag, value)
        self.Changed:Fire(value)
        if not silent then
            Utility.Call(cfg.callback, value)
        end
    end

    function toggle:Get()
        return self.Value
    end

    Utility.Connect(button.MouseButton1Click, function()
        toggle:Set(not toggle.Value)
    end)

    Finish(toggle, cfg, row)
    AttachAddons(toggle, row, self, button)
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return toggle.Value
        end,
        Set = function(value)
            toggle:Set(value == true)
        end,
    })
    toggle:Set(cfg.default)
    return toggle
end

--// Label -----------------------------------------------------------------------

function Section:Label(properties)
    local cfg = Options(properties, { name = "label" })
    local label = { Class = "Label", Name = cfg.name }

    local row = self:Row(10)
    local text = Utility.Text("text", {
        Parent = row,
        Position = fromOffset(7, 1),
        Size = UDim2.new(1, -7, 1, 0),
        Text = cfg.name,
        TextColor3 = cfg.color or "text",
        TextXAlignment = Left,
    })
    label.Label = text

    function label:Set(value)
        self.Name = tostring(value)
        text.Text = self.Name
    end

    Finish(label, cfg, row)
    AttachAddons(label, row, self)
    return label
end

function Section:Keybind(properties)
    local cfg = Options(properties, { name = "keybind" })
    local label = self:Label({ Name = cfg.name, Visible = cfg.visible })
    local keybind = label:Keybind(properties)
    keybind.Row = label
    return keybind
end

function Section:Colorpicker(properties)
    local cfg = Options(properties, { name = "color" })
    local label = self:Label({ Name = cfg.name, Visible = cfg.visible })
    local picker = label:Colorpicker(properties)
    picker.Row = label
    return picker
end

--// Slider ----------------------------------------------------------------------

function Section:Slider(properties)
    local cfg = Options(properties, { name = "slider", min = 0, max = 100, suffix = "" })
    local minimum, maximum = cfg.min, cfg.max
    local step = cfg.step or cfg.increment or cfg.decimal or 1
    local ranged = cfg.range == true
    local decimals = 0
    do
        local fraction = string.match(tostring(step), "%.(%d+)")
        decimals = fraction and #fraction or 0
    end

    local slider = { Class = "Slider", Name = cfg.name, Min = minimum, Max = maximum, Step = step, Value = minimum }

    local row = self:Row(25)
    slider.Label = Utility.Text("text", {
        Parent = row,
        Position = fromOffset(7, 0),
        Size = UDim2.new(1, -14, 0, 10),
        Text = cfg.name,
        TextXAlignment = Left,
    })

    local minus = New("TextButton", { Parent = row, Position = fromOffset(-2, 10), Size = fromOffset(9, 9) })
    Glyph(minus, fromOffset(2, 2), 5, false)
    local plus = New("TextButton", { Parent = row, Position = UDim2.new(1, -7, 0, 10), Size = fromOffset(9, 9) })
    Glyph(plus, fromOffset(2, 2), 5, true)

    local track = New("Frame", {
        Parent = row,
        Position = fromOffset(6, 12),
        Size = UDim2.new(1, -12, 0, 5),
        BackgroundColor3 = WHITE,
    })
    Utility.Gradient(track, { "track_light", "track" }, 0.6)
    local fill = New("Frame", { Parent = track, Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE })
    Utility.Gradient(fill, { "accent_light", "accent" }, 0.6)
    local value = Utility.Text("text", {
        Parent = track,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0, 0, 0, 5),
        Size = fromOffset(80, 10),
        ZIndex = 2,
    })
    local hit = New("TextButton", {
        Parent = row,
        Position = fromOffset(6, 8),
        Size = UDim2.new(1, -12, 0, 13),
        ZIndex = 3,
    })

    local function snap(number)
        number = math.clamp(tonumber(number) or minimum, minimum, maximum)
        return math.clamp(Utility.Round(number - minimum, step) + minimum, minimum, maximum)
    end

    local function format(number)
        return string.format("%." .. decimals .. "f", number) .. cfg.suffix
    end

    local function alpha(number)
        return maximum == minimum and 0 or (number - minimum) / (maximum - minimum)
    end

    function slider:Set(newValue, silent)
        if ranged then
            local low, high = minimum, maximum
            if type(newValue) == "table" then
                low = snap(newValue[1] or newValue.Min or newValue.min)
                high = snap(newValue[2] or newValue.Max or newValue.max)
            end
            if low > high then
                low, high = high, low
            end
            self.Value = { Min = low, Max = high }
            fill.Position = UDim2.fromScale(alpha(low), 0)
            fill.Size = UDim2.fromScale(alpha(high) - alpha(low), 1)
            value.Position = UDim2.new((alpha(low) + alpha(high)) / 2, 0, 0, 5)
            value.Text = format(low) .. " - " .. format(high)
        else
            self.Value = snap(newValue)
            fill.Size = UDim2.fromScale(alpha(self.Value), 1)
            value.Position = UDim2.new(alpha(self.Value), 0, 0, 5)
            value.Text = format(self.Value)
        end
        Library:SetFlag(cfg.flag, self.Value)
        self.Changed:Fire(self.Value)
        if not silent then
            Utility.Call(cfg.callback, self.Value)
        end
    end

    function slider:Get()
        return self.Value
    end

    local dragging, handle = false, "Max"

    local function drag(input, pick)
        local x = Utility.Pointer(input).X
        local target = minimum
            + (maximum - minimum) * math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        if not ranged then
            slider:Set(target)
            return
        end
        local current = slider.Value
        if pick then
            -- grab whichever end of the range is closer
            handle = math.abs(target - current.Min) < math.abs(target - current.Max) and "Min" or "Max"
        end
        if handle == "Min" then
            slider:Set({ math.min(target, current.Max), current.Max })
        else
            slider:Set({ current.Min, math.max(target, current.Min) })
        end
    end

    local function nudge(direction)
        if ranged then
            local current = slider.Value
            if handle == "Min" then
                slider:Set({ math.min(current.Min + step * direction, current.Max), current.Max })
            else
                slider:Set({ current.Min, math.max(current.Max + step * direction, current.Min) })
            end
        else
            slider:Set(slider.Value + step * direction)
        end
    end

    Utility.Connect(hit.InputBegan, function(input)
        if IsPress(input) then
            dragging = true
            drag(input, true)
        end
    end)
    Utility.Connect(UserInputService.InputChanged, function(input)
        if dragging and IsMove(input) then
            drag(input, false)
        end
    end)
    Utility.Connect(UserInputService.InputEnded, function(input)
        if IsPress(input) then
            dragging = false
        end
    end)
    Utility.Connect(minus.MouseButton1Click, function()
        nudge(-1)
    end)
    Utility.Connect(plus.MouseButton1Click, function()
        nudge(1)
    end)

    Finish(slider, cfg, row)
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            if ranged then
                return { slider.Value.Min, slider.Value.Max }
            end
            return slider.Value
        end,
        Set = function(saved)
            slider:Set(saved)
        end,
    })
    slider:Set(cfg.default or (ranged and { minimum, maximum }) or minimum)
    return slider
end

--// Dropdown --------------------------------------------------------------------

-- A label above an input box; both dropdowns and textboxes use it.
local function LabelledBox(section, cfg)
    local labelled = cfg.name ~= nil and cfg.name ~= ""
    local row = section:Row(labelled and 26 or 15)
    local label
    if labelled then
        label = Utility.Text("text", {
            Parent = row,
            Position = fromOffset(7, -1),
            Size = UDim2.new(1, -14, 0, 10),
            Text = cfg.name,
            TextXAlignment = Left,
        })
    end
    local box, fill = Utility.Box({
        Parent = row,
        Position = fromOffset(0, labelled and 11 or 0),
        Size = UDim2.new(1, 0, 0, 15),
    }, { { "border" } }, "element")
    return row, box, fill, label
end

function Section:Dropdown(properties)
    local cfg = Options(properties, { name = "dropdown", multi = false, maxvisible = 8 })
    local multi = cfg.multi == true
    local dropdown = {
        Class = "Dropdown",
        Name = cfg.name,
        Options = table.clone(cfg.options or cfg.items or cfg.values or {}),
        Multi = multi,
        Value = multi and {} or nil,
        Opened = false,
    }

    local row, box, fill, label = LabelledBox(self, cfg)
    dropdown.Label = label
    local text = Utility.Text("text", {
        Parent = fill,
        Position = fromOffset(2, 0),
        Size = UDim2.new(1, -16, 1, 0),
        TextXAlignment = Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    local _, vertical = Glyph(fill, UDim2.new(1, -9, 0, 3), 7, true)
    local button = New("TextButton", { Parent = box, Size = UDim2.fromScale(1, 1), ZIndex = 2 })

    local popup, popupFill = Utility.Box({
        Parent = Library.Overlay,
        Visible = false,
        ZIndex = 40,
        Active = true,
    }, { { "border" } }, "element")
    local scroll = New("ScrollingFrame", {
        Parent = popupFill,
        Size = UDim2.fromScale(1, 1),
        ScrollBarImageColor3 = "accent",
    })
    New("UIListLayout", { Parent = scroll })

    local rows = {}

    local function selected(option)
        if multi then
            return table.find(dropdown.Value, option) ~= nil
        end
        return dropdown.Value == option
    end

    local function render()
        if multi then
            text.Text = #dropdown.Value > 0 and table.concat(dropdown.Value, ", ") or (cfg.placeholder or "none")
        else
            text.Text = dropdown.Value ~= nil and tostring(dropdown.Value) or (cfg.placeholder or "none")
        end
        for option, entry in rows do
            Library:Bind(entry, "TextColor3", selected(option) and "accent_text" or "text")
        end
    end

    local function commit(silent)
        render()
        Library:SetFlag(cfg.flag, dropdown.Value)
        dropdown.Changed:Fire(dropdown.Value)
        if not silent then
            Utility.Call(cfg.callback, dropdown.Value)
        end
    end

    function dropdown:Set(newValue, silent)
        if multi then
            local list = {}
            if type(newValue) == "table" then
                -- keep the option order so saved configs stay stable
                for _, option in self.Options do
                    if table.find(newValue, option) then
                        table.insert(list, option)
                    end
                end
            elseif newValue ~= nil then
                list = { newValue }
            end
            self.Value = list
        else
            self.Value = newValue
        end
        commit(silent)
    end

    function dropdown:Get()
        return self.Value
    end

    local function build()
        for _, entry in rows do
            Utility.Destroy(entry)
        end
        table.clear(rows)
        for index, option in dropdown.Options do
            local entry = Utility.Text("text", {
                Class = "TextButton",
                Parent = scroll,
                Size = UDim2.new(1, 0, 0, 13),
                Text = "  " .. tostring(option),
                TextXAlignment = Left,
                LayoutOrder = index,
            })
            rows[option] = entry
            Utility.Connect(entry.MouseButton1Click, function()
                if multi then
                    local list = table.clone(dropdown.Value)
                    local at = table.find(list, option)
                    if at then
                        table.remove(list, at)
                    else
                        table.insert(list, option)
                    end
                    dropdown:Set(list)
                else
                    dropdown:Set(option)
                    Library:ClosePopup()
                end
            end)
        end
        render()
    end

    -- Replaces the option list, keeping the selection where it still exists.
    function dropdown:SetOptions(options)
        self.Options = table.clone(options)
        build()
        if multi then
            self:Set(self.Value, true)
        elseif self.Value ~= nil and not table.find(self.Options, self.Value) then
            self:Set(nil, true)
        end
    end

    dropdown.Refresh = dropdown.SetOptions

    function dropdown:Open()
        local origin = Utility.ToOffset(box.AbsolutePosition)
        local size = box.AbsoluteSize / Library.Scale
        local height = math.clamp(#self.Options, 1, cfg.maxvisible) * 13 + 2
        local y = origin.Y + size.Y - 1
        if y + height > Utility.Viewport().Y / Library.Scale then
            y = origin.Y - height + 1 -- no room below: open upwards
        end
        popup.Position = fromOffset(origin.X, y)
        popup.Size = fromOffset(size.X, height)
        popup.Visible = true
        vertical.Visible = false
        self.Opened = true
        Library:OpenPopup({
            Frame = popup,
            Owner = box,
            Close = function()
                popup.Visible = false
                vertical.Visible = true
                dropdown.Opened = false
            end,
        })
    end

    Utility.Connect(button.MouseButton1Click, function()
        if dropdown.Opened then
            Library:ClosePopup()
        else
            dropdown:Open()
        end
    end)

    Finish(dropdown, cfg, row)
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return dropdown.Value
        end,
        Set = function(saved)
            dropdown:Set(saved)
        end,
    })
    build()
    if cfg.default ~= nil then
        dropdown:Set(cfg.default)
    else
        dropdown:Set(multi and {} or dropdown.Options[1])
    end
    return dropdown
end

--// Textbox ---------------------------------------------------------------------

function Section:Textbox(properties)
    local cfg = Options(properties, { name = "textbox", default = "", placeholder = "" })
    local textbox = { Class = "Textbox", Name = cfg.name, Value = "" }

    local row, _, fill, label = LabelledBox(self, cfg)
    textbox.Label = label
    local input = Utility.Text("text", {
        Class = "TextBox",
        Parent = fill,
        Position = fromOffset(2, 0),
        Size = UDim2.new(1, -4, 1, 0),
        PlaceholderText = cfg.placeholder,
        PlaceholderColor3 = "text_dim",
        TextXAlignment = Left,
        ClipsDescendants = true,
    })
    textbox.Input = input

    function textbox:Set(newValue, silent)
        newValue = tostring(newValue == nil and "" or newValue)
        if cfg.numeric then
            newValue = tostring(tonumber(newValue) or tonumber(self.Value) or 0)
        end
        self.Value = newValue
        input.Text = newValue
        Library:SetFlag(cfg.flag, newValue)
        self.Changed:Fire(newValue)
        if not silent then
            Utility.Call(cfg.callback, newValue)
        end
    end

    function textbox:Get()
        return self.Value
    end

    Utility.Connect(input.FocusLost, function()
        textbox:Set(input.Text)
    end)

    Finish(textbox, cfg, row)
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return textbox.Value
        end,
        Set = function(saved)
            textbox:Set(saved)
        end,
    })
    textbox:Set(cfg.default, true)
    return textbox
end

--// Buttons ---------------------------------------------------------------------

-- The gradient button used by sections and by the configs / lua windows.
local function CreateButton(parent, properties, position, size, role)
    local cfg = Options(properties, { name = "button" })
    local button = { Class = "Button", Name = cfg.name }

    local outer, fill = Utility.Box({
        Parent = parent,
        Position = position,
        Size = size,
    }, role == "panel_text" and { { "border" }, { "button_outline" } } or { { "button_outline" } }, "white")
    Utility.Gradient(fill, { "button_top", "button_bottom" })
    local label = Utility.Text(role or "button", { Parent = fill, Size = UDim2.fromScale(1, 1), Text = cfg.name })
    local click = New("TextButton", { Parent = outer, Size = UDim2.fromScale(1, 1), ZIndex = 2 })

    function button:SetName(name)
        self.Name = name
        label.Text = name
    end

    function button:SetVisible(visible)
        outer.Visible = visible == true
    end

    function button:Click()
        Utility.Call(cfg.callback)
    end

    local function release()
        Library:Bind(label, "TextColor3", "text")
    end
    Utility.Connect(click.MouseButton1Down, function()
        Library:Bind(label, "TextColor3", "accent_text")
    end)
    Utility.Connect(click.MouseButton1Up, release)
    Utility.Connect(click.MouseLeave, release)
    Utility.Connect(click.MouseButton1Click, function()
        button:Click()
    end)

    button.Frame = outer
    button.Label = label
    return button
end

Utility.Button = CreateButton

-- Lays `count` buttons out in one row with a pixel gap between them.
local function ButtonSlot(index, count, gap)
    local share = gap * (count - 1) / count
    return UDim2.new((index - 1) / count, (index - 1) * (gap - share), 0, 0), UDim2.new(1 / count, -share, 1, 0)
end

Utility.ButtonSlot = ButtonSlot

-- Section:Buttons({ { Name = "a", Callback = f }, { Name = "b", Callback = g }, ... })
function Section:Buttons(list)
    local row = self:Row(16)
    local buttons = {}
    for index, properties in list do
        local position, size = ButtonSlot(index, #list, 4)
        buttons[index] = CreateButton(row, properties, position, size)
    end
    return buttons, row
end

function Section:Button(properties)
    local buttons, row = self:Buttons({ properties })
    local button = buttons[1]
    function button:SetVisible(visible)
        row.Visible = visible == true
    end
    return button
end

function Section:DoubleButton(first, second)
    local buttons = self:Buttons({ first, second })
    return buttons[1], buttons[2]
end

function Section:TripleButton(first, second, third)
    local buttons = self:Buttons({ first, second, third })
    return buttons[1], buttons[2], buttons[3]
end

--// List and divider ------------------------------------------------------------

function Section:List(properties)
    local cfg = Options(properties, { name = "", height = 100 })
    local list = { Class = "List", Name = cfg.name, Options = {}, Value = nil }
    local labelled = cfg.name ~= ""

    local row = self:Row(cfg.height + (labelled and 11 or 0))
    if labelled then
        list.Label = Utility.Text("text", {
            Parent = row,
            Position = fromOffset(7, -1),
            Size = UDim2.new(1, -14, 0, 10),
            Text = cfg.name,
            TextXAlignment = Left,
        })
    end
    local _, fill = Utility.Box({
        Parent = row,
        Position = fromOffset(0, labelled and 11 or 0),
        Size = UDim2.new(1, 0, 0, cfg.height),
    }, { { "border" } }, "element")
    local scroll = New("ScrollingFrame", {
        Parent = fill,
        Size = UDim2.fromScale(1, 1),
        ScrollBarImageColor3 = "accent",
    })
    New("UIListLayout", { Parent = scroll })

    local rows = {}

    local function render()
        for option, entry in rows do
            Library:Bind(entry, "TextColor3", option == list.Value and "accent_text" or "text")
        end
    end

    function list:Set(newValue, silent)
        self.Value = newValue
        render()
        Library:SetFlag(cfg.flag, newValue)
        self.Changed:Fire(newValue)
        if not silent then
            Utility.Call(cfg.callback, newValue)
        end
    end

    function list:Get()
        return self.Value
    end

    function list:SetOptions(options)
        for _, entry in rows do
            Utility.Destroy(entry)
        end
        table.clear(rows)
        self.Options = table.clone(options)
        for index, option in self.Options do
            local entry = Utility.Text("text", {
                Class = "TextButton",
                Parent = scroll,
                Size = UDim2.new(1, 0, 0, 13),
                Text = "  " .. tostring(option),
                TextXAlignment = Left,
                LayoutOrder = index,
            })
            rows[option] = entry
            Utility.Connect(entry.MouseButton1Click, function()
                list:Set(option)
            end)
        end
        if self.Value ~= nil and not table.find(self.Options, self.Value) then
            self:Set(nil, true)
        else
            render()
        end
    end

    list.Refresh = list.SetOptions

    Finish(list, cfg, row)
    Library:RegisterFlag(cfg.flag, {
        Save = cfg.save,
        Get = function()
            return list.Value
        end,
        Set = function(saved)
            list:Set(saved)
        end,
    })
    list:SetOptions(cfg.options or cfg.items or {})
    if cfg.default ~= nil then
        list:Set(cfg.default, true)
    end
    return list
end

-- A thin separator line, optionally with a caption.
function Section:Divider(properties)
    local cfg = Options(properties, { name = "" })
    local divider = { Class = "Divider" }
    local captioned = cfg.name ~= ""

    local row = self:Row(captioned and 10 or 5)
    New("Frame", {
        Parent = row,
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = "section_inline",
    })
    if captioned then
        -- the caption sits on a patch of section colour so it cuts the line
        local patch = New("Frame", {
            Parent = row,
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.fromScale(0.5, 0),
            Size = fromOffset(0, 10),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = "section",
        })
        New("UIPadding", { Parent = patch, PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) })
        Utility.Text("section", {
            Parent = patch,
            Size = fromOffset(0, 10),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = cfg.name,
            TextColor3 = "text_dim",
        })
    end

    return Finish(divider, cfg, row)
end

--// Brand text ------------------------------------------------------------------
-- The name on the dock and watermark. Every character can have its own colour,
-- and the letters can be animated.

Derived.accent_soft = function(theme)
    return theme.accent:Lerp(theme.accent_text, 0.7)
end

-- Turns the Name / NameColor / DomainColor / Tag options into { Text, Color, Role } parts.
local function BrandParts(cfg)
    local parts, name = {}, cfg.name
    if type(name) == "table" then
        for _, part in name do
            if type(part) == "table" then
                table.insert(parts, {
                    Text = tostring(part[1] or part.Text or part.text or ""),
                    Color = part[2] or part.Color or part.color,
                })
            else
                table.insert(parts, { Text = tostring(part) })
            end
        end
    else
        name = tostring(name)
        -- "drain.solutions": the domain runs from the first dot to the next space
        local dot = string.find(name, ".", 1, true)
        if cfg.namecolor == nil and cfg.domaincolor == nil then
            table.insert(parts, { Text = name })
        elseif not dot then
            table.insert(parts, { Text = name, Color = cfg.namecolor })
        else
            local stop = string.find(name, " ", dot, true) or (#name + 1)
            table.insert(parts, { Text = string.sub(name, 1, dot - 1), Color = cfg.namecolor })
            table.insert(parts, { Text = string.sub(name, dot, stop - 1), Color = cfg.domaincolor })
            if stop <= #name then
                table.insert(parts, { Text = string.sub(name, stop) })
            end
        end
    end
    -- the tag follows the name after a divider, in the regular hud font
    if cfg.tag ~= nil and cfg.tag ~= "" then
        table.insert(parts, { Text = " |" })
        table.insert(parts, { Text = tostring(cfg.tag), Color = cfg.tagcolor, Role = "hud" })
    end
    return parts
end

local Animations = { none = "None", bounce = "Bounce", wave = "Wave", shine = "Shine" }

local function CreateBrand(parent, role, height, cfg)
    local brand = {
        Characters = {}, -- { Text, Color, Role } per character
        Runs = {}, -- static: one rich-text label per stretch of one font
        Cells = {}, -- animated: one label per character
        Animation = Animations[string.lower(tostring(cfg.animation or "none"))] or "None",
        Speed = cfg.speed or 1,
    }

    local holder = New("Frame", {
        Parent = parent,
        BackgroundTransparency = 1,
        Size = fromOffset(0, height),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = cfg.layoutorder or 1,
    })
    New("UIListLayout", {
        Parent = holder,
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    })
    brand.Frame = holder

    local function moving()
        return brand.Animation == "Bounce" or brand.Animation == "Wave"
    end

    -- Characters without an explicit colour share the design's gradient: accent
    -- at both ends, near-white in the middle. `center` moves it for "Shine".
    local function colorAt(index, center)
        local character = brand.Characters[index]
        if character.Color ~= nil then
            return Library:GetColor(character.Color)
        end
        local accent = Library:GetColor("accent")
        local count = #brand.Characters
        local at = count > 1 and (index - 1) / (count - 1) or 0.5
        local glow = center and math.clamp(1 - math.abs(at - center) * 3, 0, 1) or 1 - math.abs(at * 2 - 1)
        return accent:Lerp(accent:Lerp(Library:GetColor("text"), 0.8), glow)
    end

    function brand:Recolor(center)
        for index, cell in self.Cells do
            if cell.Label then
                cell.Label.TextColor3 = colorAt(index, center)
            end
        end
        for _, run in self.Runs do
            local out = {}
            for index = run.First, run.Last do
                table.insert(out, string.format(
                    '<font color="%s">%s</font>',
                    Utility.RichColor(colorAt(index, center)),
                    Utility.Escape(self.Characters[index].Text)
                ))
            end
            run.Label.Text = table.concat(out)
        end
    end

    local items = {}

    -- A single label per font keeps the exact letter spacing; only the
    -- animations that move letters need one label per character.
    local function rebuild()
        for _, item in items do
            Utility.Destroy(item)
        end
        table.clear(items)
        table.clear(brand.Runs)
        table.clear(brand.Cells)

        local order, previous, run = 0, nil, nil
        for index, character in brand.Characters do
            local font = character.Role or role
            if previous and font ~= previous then
                order += 1
                table.insert(items, New("Frame", {
                    Parent = holder,
                    BackgroundTransparency = 1,
                    Size = UDim2.new(0, 3, 1, 0),
                    LayoutOrder = order,
                }))
            end
            order += 1
            if moving() then
                local cell = {}
                if character.Text == " " then
                    local style = Library.Text[font] or Library.Text.text
                    cell.Frame = New("Frame", {
                        Parent = holder,
                        BackgroundTransparency = 1,
                        Size = UDim2.new(0, math.ceil(style.Size * 0.3), 1, 0),
                        LayoutOrder = order,
                    })
                else
                    cell.Frame = New("Frame", {
                        Parent = holder,
                        BackgroundTransparency = 1,
                        Size = UDim2.new(0, 0, 1, 0),
                        AutomaticSize = Enum.AutomaticSize.X,
                        LayoutOrder = order,
                    })
                    cell.Label = Utility.Text(font, {
                        Parent = cell.Frame,
                        Size = UDim2.new(0, 0, 1, 0),
                        AutomaticSize = Enum.AutomaticSize.X,
                        Text = character.Text,
                        TextColor3 = WHITE,
                    })
                end
                brand.Cells[index] = cell
                table.insert(items, cell.Frame)
            elseif font ~= previous then
                run = {
                    First = index,
                    Last = index,
                    Label = Utility.Text(font, {
                        Parent = holder,
                        Size = UDim2.new(0, 0, 1, 0),
                        AutomaticSize = Enum.AutomaticSize.X,
                        RichText = true,
                        TextColor3 = WHITE,
                        LayoutOrder = order,
                    }),
                }
                table.insert(brand.Runs, run)
                table.insert(items, run.Label)
            else
                run.Last = index
            end
            previous = font
        end
        brand:Recolor()
    end

    function brand:SetParts(parts)
        table.clear(self.Characters)
        for _, part in parts do
            for character in string.gmatch(part.Text, utf8.charpattern) do
                table.insert(self.Characters, { Text = character, Color = part.Color, Role = part.Role })
            end
        end
        rebuild()
    end

    -- Accepts the constructor's Name / NameColor / DomainColor / Tag options.
    function brand:SetName(options)
        self:SetParts(BrandParts(Options(options)))
    end

    local connection

    local function step()
        local clock = os.clock() * brand.Speed
        if brand.Animation == "Shine" then
            -- the highlight sweeps across, then rests off the text for a moment
            brand:Recolor((clock * 0.6) % 2.2 - 0.6)
            return
        end
        local count = #brand.Characters
        for index, cell in brand.Cells do
            if cell.Label then
                local y
                if brand.Animation == "Bounce" then
                    -- one hop travels through the letters, then pauses
                    local phase = (clock - index * 0.09) % (count * 0.09 + 1.4)
                    y = phase < 0.45 and -math.sin(phase / 0.45 * math.pi) * 3 or 0
                else
                    y = math.sin(clock * 5 - index * 0.55) * 2
                end
                cell.Label.Position = fromOffset(0, math.floor(y + 0.5))
            end
        end
    end

    function brand:SetAnimation(animation)
        self.Animation = Animations[string.lower(tostring(animation))] or "None"
        if connection then
            connection:Disconnect()
            connection = nil
        end
        rebuild()
        if self.Animation ~= "None" then
            connection = Utility.Connect(RunService.RenderStepped, step)
        end
    end

    Library.ThemeChanged:Connect(function()
        brand:Recolor()
    end)

    brand:SetParts(BrandParts(cfg))
    brand:SetAnimation(brand.Animation)
    return brand
end

--// Watermark -------------------------------------------------------------------

Library.Components = {}
Library.FrameRate = 60

do
    local frames, last = 0, os.clock()
    Utility.Connect(RunService.RenderStepped, function()
        frames += 1
        local now = os.clock()
        if now - last >= 1 then
            Library.FrameRate = math.floor(frames / (now - last) + 0.5)
            frames, last = 0, now
        end
    end)
end

local function Ping()
    local ok, value = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if not (ok and type(value) == "number") then
        ok, value = pcall(function()
            return LocalPlayer:GetNetworkPing() * 1000
        end)
    end
    return ok and type(value) == "number" and math.floor(value + 0.5) or 0
end

-- Named stats for the watermark; add your own with Library.StatProviders.name = function() return "text" end
Library.StatProviders = {
    ram = function()
        local ok, value = pcall(function()
            return Stats:GetTotalMemoryUsageMb()
        end)
        return string.format("ram: %dmb", ok and value or 0)
    end,
    fps = function()
        return string.format("%d fps", Library.FrameRate)
    end,
    ping = function()
        return string.format("%d ping", Ping())
    end,
    time = function()
        return os.date("%H:%M:%S")
    end,
    date = function()
        return os.date("%d/%m/%Y")
    end,
    user = function()
        return LocalPlayer and LocalPlayer.Name or "user"
    end,
    executor = function()
        if Env.identifyexecutor then
            local ok, name = pcall(Env.identifyexecutor)
            if ok and name then
                return tostring(name)
            end
        end
        return "unknown"
    end,
}

function Library:Watermark(properties)
    self:Load()
    local cfg = Options(properties, {
        name = self.Name,
        stats = { "ram", "fps", "ping" },
        position = Vector2.new(124, 85),
        animation = "None",
        rate = 0.5,
    })
    cfg.id = "watermark"
    local position = ToVector2(cfg.position, Vector2.new(124, 85))

    local frame = New("Frame", {
        Name = "Watermark",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(0, 21),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = "element_outline",
        Active = true,
    })
    New("UIPadding", {
        Parent = frame,
        PaddingTop = UDim.new(0, 1),
        PaddingBottom = UDim.new(0, 1),
        PaddingLeft = UDim.new(0, 1),
        PaddingRight = UDim.new(0, 1),
    })
    local inner = New("Frame", {
        Parent = frame,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = "background",
    })
    New("UIPadding", { Parent = inner, PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9) })
    New("UIListLayout", {
        Parent = inner,
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding = UDim.new(0, 14),
    })

    local watermark = setmetatable({ Frame = frame, Stats = cfg.stats }, Panel)

    -- the brand sits a pixel lower than the stats, as in the design
    local brandHolder = New("Frame", {
        Parent = inner,
        BackgroundTransparency = 1,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = 1,
    })
    New("UIPadding", { Parent = brandHolder, PaddingTop = UDim.new(0, 1) })
    watermark.Brand = CreateBrand(brandHolder, "watermark_brand", 18, cfg)

    local stats = Utility.Text("watermark", {
        Parent = inner,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = 2,
    })

    function watermark:Update()
        local values = {}
        for _, stat in self.Stats do
            local provider = type(stat) == "function" and stat or Library.StatProviders[stat]
            local text = stat
            if provider then
                local ok, result = pcall(provider)
                text = ok and result or nil
            end
            if text ~= nil and text ~= "" then
                table.insert(values, tostring(text))
            end
        end
        stats.Text = table.concat(values, " | ")
        stats.Visible = #values > 0
    end

    -- Accepts the same Name / NameColor / DomainColor options as the constructor.
    function watermark:SetName(options)
        self.Brand:SetName(options)
    end

    function watermark:SetStats(list)
        self.Stats = list
        self:Update()
    end

    function watermark:SetAnimation(animation, speed)
        if speed then
            self.Brand.Speed = speed
        end
        self.Brand:SetAnimation(animation)
    end

    Utility.Drag(frame, frame, nil, function()
        return Library.Open
    end)

    local elapsed = cfg.rate
    Utility.Connect(RunService.Heartbeat, function(delta)
        elapsed += delta
        if elapsed >= cfg.rate and watermark.Enabled then
            elapsed = 0
            watermark:Update()
        end
    end)

    SetupPanel(watermark, cfg, true)
    watermark:Update()
    self.Components.Watermark = watermark
    return watermark
end

--// Keybind list ----------------------------------------------------------------

function Library:KeybindList(properties)
    self:Load()
    local cfg = Options(properties, {
        name = "keybinds",
        mode = "All", -- "All": every bind, active ones highlighted; "Active": only active binds
        showkeys = true,
        activecolor = "accent_text",
        position = Vector2.new(123, 269),
    })
    cfg.id = "keybinds"
    local position = ToVector2(cfg.position, Vector2.new(123, 269))

    local frame = New("Frame", {
        Name = "Keybinds",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundColor3 = "element_outline",
        Active = true,
    })
    New("UIPadding", {
        Parent = frame,
        PaddingTop = UDim.new(0, 1),
        PaddingBottom = UDim.new(0, 1),
        PaddingLeft = UDim.new(0, 1),
        PaddingRight = UDim.new(0, 1),
    })
    local inner = New("Frame", {
        Parent = frame,
        AutomaticSize = Enum.AutomaticSize.XY,
        BackgroundColor3 = "background",
    })
    New("UISizeConstraint", { Parent = inner, MinSize = Vector2.new(128, 16) })
    New("UIPadding", {
        Parent = inner,
        PaddingTop = UDim.new(0, 2),
        PaddingLeft = UDim.new(0, 3),
        PaddingRight = UDim.new(0, 5),
    })
    New("UIListLayout", { Parent = inner, Padding = UDim.new(0, 2) })

    local list = setmetatable({
        Frame = frame,
        Mode = string.lower(tostring(cfg.mode)) == "active" and "Active" or "All",
        ShowKeys = cfg.showkeys ~= false,
        ShowModes = cfg.showmodes == true,
        KeyColor = cfg.keycolor, -- nil: same colour as the row
        ActiveColor = cfg.activecolor,
    }, Panel)

    Utility.Text("hud", {
        Parent = inner,
        Size = fromOffset(0, 14),
        AutomaticSize = Enum.AutomaticSize.X,
        Text = cfg.name,
        TextColor3 = "accent_text",
        LayoutOrder = 0,
    })

    local rows = {}

    function list:Refresh()
        Panel.Refresh(self)
        for _, row in rows do
            Utility.Destroy(row)
        end
        table.clear(rows)

        for index, keybind in Library.Keybinds do
            local active = keybind:IsActive()
            if not keybind.Hidden and (self.Mode == "All" or active) then
                local text = Utility.Escape(keybind.Name)
                if self.ShowModes then
                    text ..= " (" .. string.lower(keybind.Mode) .. ")"
                end
                if self.ShowKeys then
                    local key = "[" .. Utility.KeyName(keybind.Key) .. "]"
                    if self.KeyColor ~= nil then
                        key = string.format(
                            '<font color="%s">%s</font>',
                            Utility.RichColor(Library:GetColor(self.KeyColor)),
                            key
                        )
                    end
                    text ..= " - " .. key
                end
                table.insert(rows, Utility.Text("hud", {
                    Parent = inner,
                    Size = fromOffset(0, 14),
                    AutomaticSize = Enum.AutomaticSize.X,
                    RichText = true,
                    Text = text,
                    TextColor3 = (active and self.Mode == "All") and self.ActiveColor or "text",
                    LayoutOrder = index,
                }))
            end
        end
    end

    local queued = false
    local function schedule()
        if queued then
            return
        end
        queued = true
        task.defer(function()
            queued = false
            if not Library.Unloaded then
                list:Refresh()
            end
        end)
    end

    function list:SetMode(mode)
        self.Mode = string.lower(tostring(mode)) == "active" and "Active" or "All"
        schedule()
    end

    function list:SetShowKeys(show)
        self.ShowKeys = show == true
        schedule()
    end

    function list:SetKeyColor(color)
        self.KeyColor = color
        schedule()
    end

    function list:SetActiveColor(color)
        self.ActiveColor = color
        schedule()
    end

    Library.KeybindsChanged:Connect(schedule)
    Library.Changed:Connect(function(flag)
        -- a toggle turning off deactivates the bind attached to it
        local option = Library.Options[flag]
        if option and option.Class == "Toggle" then
            schedule()
        end
    end)
    Library.ThemeChanged:Connect(schedule)

    Utility.Drag(frame, frame, nil, function()
        return Library.Open
    end)

    SetupPanel(list, cfg, true)
    self.Components.KeybindList = list
    return list
end

--// Hitlogs ---------------------------------------------------------------------

-- Builds a RichText string from "plain" strings and { text, colour } pairs.
local function RichParts(parts)
    if type(parts) ~= "table" then
        return Utility.Escape(parts)
    end
    local out = {}
    for _, part in parts do
        if type(part) == "table" then
            local color = Library:GetColor(part[2] or part.Color or part.color or "accent_text")
            table.insert(out, string.format(
                '<font color="%s">%s</font>',
                Utility.RichColor(color),
                Utility.Escape(part[1] or part.Text or part.text or "")
            ))
        else
            table.insert(out, Utility.Escape(part))
        end
    end
    return table.concat(out)
end

Utility.RichParts = RichParts

local Sides = { left = "Left", right = "Right", top = "Top", bottom = "Bottom" }
local LogAnimations = { slide = "Slide", fade = "Fade", bounce = "Bounce", back = "Back" }
local ENTRY_HEIGHT, ENTRY_GAP = 19, 3

function Library:Hitlogs(properties)
    self:Load()
    local cfg = Options(properties, {
        position = Vector2.new(124, 330),
        side = "Left", -- screen edge the entries fly in from
        animation = "Slide", -- Slide, Bounce, Back or Fade
        duration = 4,
        speed = 0.35,
        max = 6,
    })
    cfg.id = "hitlogs"
    local position = ToVector2(cfg.position, Vector2.new(124, 330))

    local logs = setmetatable({
        Entries = {},
        Side = Sides[string.lower(tostring(cfg.side))] or "Left",
        Animation = LogAnimations[string.lower(tostring(cfg.animation))] or "Slide",
        Duration = cfg.duration,
        Speed = cfg.speed,
        Max = cfg.max,
    }, Panel)

    -- drag handle; it marks where the stack starts and only shows with the menu
    local handle, handleFill = Utility.Box({
        Name = "Hitlogs",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(60, 16),
        Active = true,
    }, { { "element_outline" } }, "background")
    Utility.Text("hud", {
        Parent = handleFill,
        Size = UDim2.fromScale(1, 1),
        Text = "hitlogs",
        TextColor3 = "text_dim",
    })
    logs.Frame = handle

    function logs:Refresh()
        handle.Visible = self.Enabled and Library.Open
        if not self.Enabled then
            -- switching the hitlogs off also takes down what is on screen
            for _, entry in self.Entries do
                entry.Leaving = true
                Utility.Destroy(entry.Frame)
            end
            table.clear(self.Entries)
        end
    end

    local function align()
        if logs.Side == "Right" then
            return Vector2.new(1, 0)
        elseif logs.Side == "Left" then
            return Vector2.new(0, 0)
        end
        return Vector2.new(0.5, 0)
    end

    local function origin()
        -- the stack hangs below the handle, lined up with the edge it follows
        local anchor = align()
        return Vector2.new(handle.Position.X.Offset + 60 * anchor.X, handle.Position.Y.Offset + 16 + ENTRY_GAP)
    end

    local function slot(index)
        local start = origin()
        return Vector2.new(start.X, start.Y + (index - 1) * (ENTRY_HEIGHT + ENTRY_GAP))
    end

    -- where an entry starts (and ends) its flight for the current side
    local function offscreen(target)
        local view = Utility.Viewport() / Library.Scale
        if logs.Side == "Left" then
            return Vector2.new(-420, target.Y)
        elseif logs.Side == "Right" then
            return Vector2.new(view.X + 420, target.Y)
        elseif logs.Side == "Top" then
            return Vector2.new(target.X, -40)
        end
        return Vector2.new(target.X, view.Y + 40)
    end

    local function fade(entry, alpha)
        entry.Frame.BackgroundTransparency = alpha
        entry.Inner.BackgroundTransparency = alpha
        entry.Line.BackgroundTransparency = alpha
        entry.Label.TextTransparency = alpha
        entry.Stroke.Transparency = alpha
    end

    function logs:Restack()
        for index, entry in self.Entries do
            entry.Anchor = align()
            entry.Frame.AnchorPoint = entry.Anchor
            local target = slot(index)
            if entry.Settled then
                Utility.Tween(entry.Frame, { Position = fromOffset(target.X, target.Y) }, 0.2)
            end
            entry.Target = target
        end
    end

    function logs:Remove(entry)
        local index = table.find(self.Entries, entry)
        if not index or entry.Leaving then
            return
        end
        entry.Leaving = true
        table.remove(self.Entries, index)
        self:Restack()

        local from = Vector2.new(entry.Frame.Position.X.Offset, entry.Frame.Position.Y.Offset)
        local to = self.Animation == "Fade" and from or offscreen(from)
        Utility.Animate(self.Speed, function(alpha)
            local eased = alpha * alpha
            local at = from:Lerp(to, eased)
            entry.Frame.Position = fromOffset(at.X, at.Y)
            fade(entry, eased)
        end, function()
            Utility.Destroy(entry.Frame)
        end)
    end

    -- logs:Add("plain text") or logs:Add({ "hit ", { "player", "accent_text" }, " for ", { "100", Color3 } })
    function logs:Add(parts, options)
        local settings = Options(options, { duration = self.Duration })
        if not self.Enabled then
            return nil
        end
        while #self.Entries >= self.Max do
            self:Remove(self.Entries[1])
        end

        local entry = { Settled = false, Anchor = align() }
        entry.Frame = New("Frame", {
            Parent = Library.Root,
            AnchorPoint = entry.Anchor,
            Size = fromOffset(0, ENTRY_HEIGHT),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = "element_outline",
            ZIndex = 5,
        })
        New("UIPadding", {
            Parent = entry.Frame,
            PaddingTop = UDim.new(0, 1),
            PaddingBottom = UDim.new(0, 1),
            PaddingLeft = UDim.new(0, 1),
            PaddingRight = UDim.new(0, 1),
        })
        entry.Inner = New("Frame", {
            Parent = entry.Frame,
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = "background",
        })
        New("UIPadding", { Parent = entry.Inner, PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 6) })
        entry.Line = New("Frame", {
            Parent = entry.Inner,
            Position = fromOffset(-8, 0),
            Size = UDim2.new(0, 2, 1, 0),
            BackgroundColor3 = settings.color or "accent",
        })
        entry.Label = Utility.Text("hud", {
            Parent = entry.Inner,
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            RichText = true,
            Text = RichParts(parts),
        })
        entry.Stroke = entry.Label:FindFirstChildOfClass("UIStroke")

        table.insert(self.Entries, entry)
        local target = slot(#self.Entries)
        entry.Target = target

        local from = self.Animation == "Fade" and target or offscreen(target)
        local ease = Utility.Easing[self.Animation == "Slide" and "Smooth" or self.Animation] or Utility.Easing.Smooth
        entry.Frame.Position = fromOffset(from.X, from.Y)
        fade(entry, self.Animation == "Fade" and 1 or 0)

        Utility.Animate(self.Speed, function(alpha)
            if entry.Leaving then
                return
            end
            if logs.Animation == "Fade" then
                fade(entry, 1 - alpha)
                entry.Frame.Position = fromOffset(entry.Target.X, entry.Target.Y)
            else
                local at = from:Lerp(entry.Target, ease(alpha))
                entry.Frame.Position = fromOffset(at.X, at.Y)
            end
        end, function()
            entry.Settled = true
        end)

        task.delay(settings.duration, function()
            if not Library.Unloaded then
                logs:Remove(entry)
            end
        end)
        return entry
    end

    function logs:SetSide(side)
        self.Side = Sides[string.lower(tostring(side))] or "Left"
        self:Restack()
    end

    function logs:SetAnimation(animation)
        self.Animation = LogAnimations[string.lower(tostring(animation))] or "Slide"
    end

    function logs:Clear()
        for _, entry in table.clone(self.Entries) do
            self:Remove(entry)
        end
    end

    Utility.Drag(handle, handle, function()
        logs:Restack()
    end)
    Utility.Connect(handle:GetPropertyChangedSignal("Position"), function()
        logs:Restack()
    end)

    SetupPanel(logs, cfg, true)
    self.Components.Hitlogs = logs
    return logs
end

-- Shows a message through the hitlog stack when there is one.
function Library:Notify(parts, duration)
    local logs = self.Components.Hitlogs
    if logs and logs.Enabled then
        return logs:Add(parts, { Duration = duration })
    end
    print(string.format("[%s] %s", self.Name, (string.gsub(RichParts(parts), "<[^>]+>", ""))))
    return nil
end

--// Target hud ------------------------------------------------------------------

local Thumbnails = {}

local function Thumbnail(userId, callback)
    local cached = Thumbnails[userId]
    if cached then
        callback(cached)
        return
    end
    task.spawn(function()
        local ok, content = pcall(function()
            return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
        end)
        if ok and content then
            Thumbnails[userId] = content
            callback(content)
        end
    end)
end

local function CharacterOf(target)
    if typeof(target) ~= "Instance" then
        return nil
    end
    if target:IsA("Player") then
        return target.Character
    end
    return target
end

local function RootOf(character)
    return character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
end

function Library:TargetHud(properties)
    self:Load()
    local cfg = Options(properties, {
        mode = "Static", -- "Static": fixed, draggable; "Attached": follows the target on screen
        position = Vector2.new(700, 560),
        offset = Vector2.new(40, -30), -- from the target's root, in "Attached" mode
        width = 170,
        stats = { "health", "distance" },
        healthcolor = rgb(120, 220, 110),
        lowhealthcolor = rgb(220, 80, 80),
        armorcolor = rgb(90, 150, 255),
    })
    cfg.id = "targethud"
    local position = ToVector2(cfg.position, Vector2.new(700, 560))
    local width = cfg.width

    local frame, fill = Utility.Box({
        Name = "TargetHud",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(width, 48),
        Active = true,
        Visible = false,
    }, { { "element_outline" } }, "background")
    New("Frame", { Parent = fill, Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = "accent" })

    -- Elements = { Avatar = false, Armor = true, ... } switches individual parts
    local wanted = Options(cfg.elements)
    local hud = setmetatable({
        Frame = frame,
        Mode = string.lower(tostring(cfg.mode)) == "attached" and "Attached" or "Static",
        Offset = ToVector2(cfg.offset, Vector2.new(40, -30)),
        Target = nil,
        Stats = cfg.stats,
        Info = {}, -- extra lines: { Key, Text }
        Elements = {
            Avatar = wanted.avatar ~= false,
            Name = wanted.name ~= false,
            Role = wanted.role ~= false,
            Stats = wanted.stats ~= false,
            Health = wanted.health ~= false,
            Armor = wanted.armor == true or (wanted.armor == nil and cfg.armor ~= nil),
        },
    }, Panel)

    local avatarBox, avatarFill = Utility.Box({ Parent = fill, Size = fromOffset(36, 36) }, { { "element_outline" } }, "element")
    local avatar = New("ImageLabel", { Parent = avatarFill, Size = UDim2.fromScale(1, 1) })
    local initial = Utility.Text("title", { Parent = avatarFill, Size = UDim2.fromScale(1, 1), Text = "?" })

    local function line(color)
        return Utility.Text("hud", {
            Parent = fill,
            Size = UDim2.new(1, -8, 0, 12),
            TextColor3 = color,
            TextXAlignment = Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        })
    end
    local nameLabel, roleLabel, statsLabel = line("accent_text"), line("text_dim"), line("text")
    local infoLabels = {}

    local function bar()
        local outer, inner = Utility.Box({ Parent = fill, Size = UDim2.new(1, -8, 0, 6) }, { { "element_outline" } }, "track")
        local value = New("Frame", { Parent = inner, Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE })
        New("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(WHITE, rgb(190, 190, 190)),
            Parent = value,
        })
        return outer, value
    end
    local healthBar, healthFill = bar()
    local armorBar, armorFill = bar()

    -- Positions the enabled elements and resizes the box around them.
    function hud:Layout()
        local elements = self.Elements
        local pad, y = 4, 5
        local textX = elements.Avatar and pad + 36 + 5 or pad

        avatarBox.Visible = elements.Avatar
        avatarBox.Position = fromOffset(pad, 5)

        local lines = {
            { nameLabel, elements.Name },
            { roleLabel, elements.Role },
            { statsLabel, elements.Stats },
        }
        for _, info in self.Info do
            local label = infoLabels[info.Key]
            if not label then
                label = line("text")
                infoLabels[info.Key] = label
            end
            label.Text = info.Text
            table.insert(lines, { label, true })
        end
        for key, label in infoLabels do
            local kept = false
            for _, info in self.Info do
                kept = kept or info.Key == key
            end
            if not kept then
                Utility.Destroy(label)
                infoLabels[key] = nil
            end
        end

        for _, entry in lines do
            local label, shown = entry[1], entry[2]
            label.Visible = shown
            if shown then
                label.Position = fromOffset(textX, y)
                label.Size = UDim2.new(1, -textX - pad, 0, 12)
                y += 12
            end
        end
        if elements.Avatar then
            y = math.max(y, 5 + 36)
        end
        y += 3

        for _, entry in { { healthBar, elements.Health }, { armorBar, elements.Armor } } do
            entry[1].Visible = entry[2]
            if entry[2] then
                entry[1].Position = fromOffset(pad, y)
                y += 6 + 3
            end
        end
        frame.Size = fromOffset(width, y + 1 + 2)
    end

    function hud:SetElement(name, enabled)
        for key in self.Elements do
            if string.lower(key) == string.lower(tostring(name)) then
                self.Elements[key] = enabled == true
            end
        end
        self:Layout()
    end

    -- hud:SetInfo("weapon", "ak-47") adds or updates a line; nil removes it.
    function hud:SetInfo(key, text)
        for index, info in self.Info do
            if info.Key == key then
                if text == nil then
                    table.remove(self.Info, index)
                else
                    info.Text = tostring(text)
                end
                self:Layout()
                return
            end
        end
        if text ~= nil then
            table.insert(self.Info, { Key = key, Text = tostring(text) })
            self:Layout()
        end
    end

    function hud:SetMode(mode)
        self.Mode = string.lower(tostring(mode)) == "attached" and "Attached" or "Static"
        if self.Mode == "Static" and self.StaticPosition then
            frame.Position = fromOffset(self.StaticPosition.X, self.StaticPosition.Y)
        end
    end

    local shown -- the target currently drawn (the local player while positioning)

    local function describe(target)
        local player = target:IsA("Player") and target or Players:GetPlayerFromCharacter(target)
        nameLabel.Text = player and player.DisplayName or target.Name

        local role
        if type(cfg.role) == "function" then
            local ok, result = pcall(cfg.role, player or target)
            role = ok and result or nil
        elseif player and cfg.groupid then
            roleLabel.Text = "..."
            task.spawn(function()
                local ok, result = pcall(function()
                    return player:GetRoleInGroup(cfg.groupid)
                end)
                if ok and shown == target then
                    roleLabel.Text = string.lower(tostring(result))
                end
            end)
            role = false
        elseif player then
            role = player.Team and player.Team.Name or ("@" .. player.Name)
        end
        if role ~= false then
            roleLabel.Text = role and tostring(role) or "npc"
        end

        avatar.Image = ""
        initial.Visible = true
        initial.Text = string.upper(string.sub(nameLabel.Text, 1, 1))
        if player then
            Thumbnail(player.UserId, function(content)
                if shown == target then
                    avatar.Image = content
                    initial.Visible = false
                end
            end)
        end
    end

    function hud:SetTarget(target)
        if typeof(target) ~= "Instance" then
            target = nil
        end
        self.Target = target
    end

    -- Manual armor value for games without a callback: hud:SetArmor(50, 100)
    function hud:SetArmor(value, maximum)
        self.ArmorValue, self.ArmorMax = value, maximum or 100
    end

    function hud:Refresh()
        if not self.Enabled then
            frame.Visible = false
        end
    end

    local builtin = {
        health = function(_, character)
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            return humanoid and string.format("hp: %d", math.floor(humanoid.Health + 0.5)) or nil
        end,
        distance = function(_, character)
            local root, mine = RootOf(character), RootOf(LocalPlayer and LocalPlayer.Character)
            if root and mine then
                return string.format("dist: %dm", math.floor((root.Position - mine.Position).Magnitude + 0.5))
            end
            return nil
        end,
    }

    local elapsed = 1
    Utility.Connect(RunService.RenderStepped, function(delta)
        if not hud.Enabled then
            return
        end
        -- while the menu is open the local player stands in so the box can be placed
        local target = hud.Target
        if target and not target.Parent then
            target = nil
        end
        if not target and Library.Open and hud.Mode == "Static" then
            target = LocalPlayer
        end
        if not target then
            frame.Visible = false
            shown = nil
            return
        end
        if shown ~= target then
            shown = target
            describe(target)
            elapsed = 1
        end

        local character = CharacterOf(target)
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if humanoid then
            local health = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
            healthFill.Size = UDim2.fromScale(health, 1)
            healthFill.BackgroundColor3 = cfg.lowhealthcolor:Lerp(cfg.healthcolor, health)
        end
        if hud.Elements.Armor then
            local value, maximum = hud.ArmorValue or 0, hud.ArmorMax or 100
            if type(cfg.armor) == "function" then
                local ok, current, limit = pcall(cfg.armor, target, character)
                if ok and type(current) == "number" then
                    value, maximum = current, limit or 100
                end
            end
            armorFill.Size = UDim2.fromScale(math.clamp(value / math.max(maximum, 1), 0, 1), 1)
            armorFill.BackgroundColor3 = cfg.armorcolor
        end

        elapsed += delta
        if elapsed >= 0.1 then
            elapsed = 0
            local values = {}
            for _, stat in hud.Stats do
                local provider = type(stat) == "function" and stat or builtin[stat]
                if provider then
                    local ok, text = pcall(provider, target, character)
                    if ok and text then
                        table.insert(values, tostring(text))
                    end
                end
            end
            statsLabel.Text = table.concat(values, " | ")
        end

        if hud.Mode == "Attached" and hud.Target then
            local root, camera = RootOf(character), Workspace.CurrentCamera
            if not (root and camera) then
                frame.Visible = false
                return
            end
            local point, visible = camera:WorldToViewportPoint(root.Position)
            if not visible then
                frame.Visible = false
                return
            end
            local at = Vector2.new(point.X, point.Y) / Library.Scale + hud.Offset
            frame.Position = fromOffset(math.floor(at.X), math.floor(at.Y))
        end
        frame.Visible = true
    end)

    Utility.Drag(frame, frame, function(moved)
        hud.StaticPosition = moved
    end, function()
        return Library.Open and hud.Mode == "Static"
    end)
    hud.StaticPosition = position

    -- configs remember the static position, not wherever a target dragged the box
    function hud:GetPosition()
        return self.StaticPosition
    end

    function hud:SetPosition(moved)
        moved = ToVector2(moved)
        if moved then
            self.StaticPosition = moved
            if self.Mode == "Static" then
                frame.Position = fromOffset(moved.X, moved.Y)
            end
        end
    end

    SetupPanel(hud, cfg, true)
    hud:Layout()
    self.Components.TargetHud = hud
    return hud
end

--// Dock ------------------------------------------------------------------------

function Library:Dock(properties)
    self:Load()
    local cfg = Options(properties, { name = self.Name, mode = "Top" })
    cfg.id = "dock"

    local frame = New("Frame", {
        Name = "Dock",
        Parent = self.Root,
        BackgroundColor3 = "element_outline",
        Active = true,
        ZIndex = 8,
    })
    local padding = New("UIPadding", { Parent = frame })
    local bar = New("Frame", { Parent = frame, BackgroundColor3 = "dock" })
    New("UIPadding", { Parent = bar, PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 6) })
    New("UIListLayout", {
        Parent = bar,
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        Padding = UDim.new(0, 8),
    })

    local dock = setmetatable({
        Frame = frame,
        Items = {},
        Mode = "Top",
        FloatOffset = ToVector2(cfg.position, Vector2.new(0, 8)),
    }, Panel)

    cfg.layoutorder = 0
    dock.Brand = CreateBrand(bar, "brand", 18, cfg)

    -- "Top": a bar pinned across the top edge. "Float": a compact bar in the
    -- upper centre that can be dragged while the menu is open.
    function dock:SetMode(mode)
        local float = string.lower(tostring(mode)) == "float"
        self.Mode = float and "Float" or "Top"
        local edge = UDim.new(0, float and 1 or 0)
        padding.PaddingTop, padding.PaddingLeft, padding.PaddingRight = edge, edge, edge
        padding.PaddingBottom = UDim.new(0, 1)
        if float then
            frame.AnchorPoint = Vector2.new(0.5, 0)
            frame.AutomaticSize = Enum.AutomaticSize.X
            frame.Size = fromOffset(0, 20)
            frame.Position = UDim2.new(0.5, self.FloatOffset.X, 0, self.FloatOffset.Y)
            bar.AutomaticSize = Enum.AutomaticSize.X
            bar.Size = UDim2.new(0, 0, 1, 0)
        else
            frame.AnchorPoint = Vector2.new(0, 0)
            frame.AutomaticSize = Enum.AutomaticSize.None
            frame.Size = UDim2.new(1, 0, 0, 19)
            frame.Position = fromOffset(0, 0)
            bar.AutomaticSize = Enum.AutomaticSize.None
            bar.Size = UDim2.fromScale(1, 1)
        end
    end

    function dock:GetPosition()
        return self.FloatOffset
    end

    function dock:SetPosition(offset)
        offset = ToVector2(offset)
        if offset then
            self.FloatOffset = offset
            if self.Mode == "Float" then
                frame.Position = UDim2.new(0.5, offset.X, 0, offset.Y)
            end
        end
    end

    -- dock:Add("menu", window) toggles a panel; dock:Add("panic", function() ... end)
    -- adds a plain button; dock:Add("esp", { Get = fn, Set = fn }) toggles anything.
    function dock:Add(name, target)
        local item = { Name = name, Target = target }
        local button = Utility.Text("dock", {
            Class = "TextButton",
            Parent = bar,
            Size = fromOffset(0, 18),
            AutomaticSize = Enum.AutomaticSize.X,
            Text = name,
            LayoutOrder = #self.Items + 1,
        })
        New("UIPadding", { Parent = button, PaddingTop = UDim.new(0, 2) })
        item.Button = button

        local function isOn()
            if type(target) == "table" then
                if target.IsVisible then
                    return target:IsVisible()
                elseif target.Get then
                    return target.Get() == true
                end
            end
            return false
        end

        function item:Render()
            Library:Bind(button, "TextColor3", isOn() and "accent_soft" or "text")
        end

        Utility.Connect(button.MouseButton1Click, function()
            if type(target) == "function" then
                Utility.Call(target)
            elseif type(target) == "table" then
                if target.SetVisible then
                    target:SetVisible(not target:IsVisible())
                elseif target.Set then
                    target.Set(not isOn())
                end
            end
            item:Render()
        end)
        if type(target) == "table" and target.VisibilityChanged then
            target.VisibilityChanged:Connect(function()
                item:Render()
            end)
        end

        item:Render()
        table.insert(self.Items, item)
        return item
    end

    function dock:SetName(options)
        self.Brand:SetName(options)
    end

    Utility.Drag(frame, frame, function(moved)
        dock.FloatOffset = moved
    end, function()
        return dock.Mode == "Float"
    end)

    SetupPanel(dock, cfg)
    dock:SetMode(cfg.mode)
    self.Components.Dock = dock
    return dock
end

--// Esp preview -----------------------------------------------------------------

function Library:EspPreview(properties)
    self:Load()
    local cfg = Options(properties, {
        name = "esp preview",
        text = "no preview for ya today",
        size = Vector2.new(229, 352),
        position = Vector2.new(655, 112),
        character = true,
    })
    cfg.id = "preview"
    local size = ToVector2(cfg.size, Vector2.new(229, 352))
    local position = ToVector2(cfg.position, Vector2.new(655, 112))

    local frame = New("Frame", {
        Name = "Preview",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(size.X, size.Y),
        BackgroundColor3 = "element_outline",
        Active = true,
    })
    local preview = setmetatable({ Frame = frame }, Panel)

    preview.Title = Utility.Text("preview_title", {
        Parent = frame,
        Size = UDim2.new(1, 0, 0, 37),
        Text = cfg.name,
        TextColor3 = "accent_text",
    })
    local _, fill = Utility.Box({
        Parent = frame,
        Position = fromOffset(2, 37),
        Size = UDim2.new(1, -4, 1, -39),
    }, { { "inline" } }, "background")
    preview.Holder = fill -- parent your own preview overlays here

    local image = New("ImageLabel", {
        Parent = fill,
        Position = fromOffset(0, 4),
        Size = UDim2.new(1, 0, 1, -8),
        ScaleType = Enum.ScaleType.Fit,
        Visible = false,
    })
    local viewport = New("ViewportFrame", {
        Parent = fill,
        Position = fromOffset(0, 4),
        Size = UDim2.new(1, 0, 1, -8),
        Ambient = rgb(200, 200, 200),
        LightColor = WHITE,
        Visible = false,
    })
    local world = New("WorldModel", { Parent = viewport })
    local camera = New("Camera", { FieldOfView = 30, Parent = viewport })
    viewport.CurrentCamera = camera

    preview.Label = Utility.Text("hud", {
        Parent = fill,
        Position = UDim2.new(0, 5, 1, -15),
        Size = UDim2.new(1, -10, 0, 14),
        Text = cfg.text,
        TextXAlignment = Left,
        ZIndex = 3,
    })

    function preview:SetText(text)
        self.Label.Text = tostring(text or "")
    end

    -- Accepts an rbxassetid:// id, or an http(s) image url on executors with getcustomasset.
    function preview:SetImage(source)
        if type(source) == "string" and string.match(source, "^https?://") then
            local path = Library.Folder .. "/preview.png"
            local data = Env.getcustomasset and Files.Supported and Download(source)
            if not (data and Files.Write(path, data)) then
                return false
            end
            local ok, asset = pcall(Env.getcustomasset, path)
            if not ok then
                return false
            end
            source = asset
        end
        image.Image = source or ""
        image.Visible = source ~= nil and source ~= ""
        viewport.Visible = false
        return true
    end

    -- Shows a clone of a character model in the viewport (nil clears it).
    function preview:SetCharacter(character)
        world:ClearAllChildren()
        viewport.Visible = false
        if typeof(character) ~= "Instance" then
            return false
        end
        local ok, clone = pcall(function()
            character.Archivable = true
            return character:Clone()
        end)
        if not (ok and clone) then
            return false
        end
        for _, descendant in clone:GetDescendants() do
            if descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound") then
                descendant:Destroy()
            elseif descendant:IsA("BasePart") then
                descendant.Anchored = true
            end
        end
        clone.Parent = world

        local pivot, bounds = clone:GetBoundingBox()
        local distance = (bounds.Y / 2) / math.tan(math.rad(camera.FieldOfView / 2)) + bounds.Z
        camera.CFrame = CFrame.lookAt(pivot.Position + pivot.LookVector * distance * 1.1, pivot.Position)
        image.Visible = false
        viewport.Visible = true
        return true
    end

    local handle = New("Frame", { Parent = frame, Size = UDim2.new(1, 0, 0, 37), BackgroundTransparency = 1, Active = true })
    Utility.Drag(handle, frame)

    if cfg.image then
        preview:SetImage(cfg.image)
    elseif cfg.character and LocalPlayer then
        task.spawn(function()
            local character = LocalPlayer.Character
            if character then
                preview:SetCharacter(character)
            end
        end)
        Utility.Connect(LocalPlayer.CharacterAdded, function(character)
            task.wait(1) -- let the appearance load before cloning
            if not Library.Unloaded and not image.Visible then
                preview:SetCharacter(character)
            end
        end)
    end

    SetupPanel(preview, cfg)
    self.Components.Preview = preview
    return preview
end

--// Configs window --------------------------------------------------------------

-- The frame shared by the configs and lua windows: border, title and a container.
-- `header` is the title strip height and `bottom` the gap under the container.
local function PanelWindow(name, cfg, layers, containerLayers, containerFill, header, titleY, bottom)
    local size, position = ToVector2(cfg.size), ToVector2(cfg.position)
    local frame, fill = Utility.Box({
        Name = name,
        Parent = Library.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(size.X, size.Y),
        Active = true,
    }, layers, "background")
    local title = Utility.Text("panel_title", {
        Parent = fill,
        Position = fromOffset(0, titleY),
        Size = UDim2.new(1, 0, 0, header),
        Text = cfg.name,
        TextColor3 = "accent_text",
        ZIndex = 2,
    })
    local handle = New("Frame", { Parent = fill, Size = UDim2.new(1, 0, 0, header), BackgroundTransparency = 1, Active = true })
    Utility.Drag(handle, frame)
    local _, container = Utility.Box({
        Parent = fill,
        Position = fromOffset(4, header),
        Size = UDim2.new(1, -8, 1, -header - bottom),
    }, containerLayers, containerFill)
    return frame, container, title
end

function Library:Configs(properties)
    self:Load()
    local cfg = Options(properties, {
        name = "configs",
        size = Vector2.new(405, 343),
        position = Vector2.new(904, 112),
    })
    cfg.id = "configs"

    local frame, container = PanelWindow(
        "Configs", cfg, { { "outline" }, { "inline" } }, { { "border" }, { "panel_inline" } }, "background", 42, 3, 4
    )
    local configs = setmetatable({ Frame = frame, Selected = nil, Rows = {} }, Panel)

    local _, listFill = Utility.Box({
        Parent = container,
        Position = fromOffset(3, 3),
        Size = UDim2.new(1, -6, 1, -96),
    }, { { "border" }, { "panel_inline" } }, "white")
    Utility.Gradient(listFill, { "list_top", "list_bottom" })
    local scroll = New("ScrollingFrame", {
        Parent = listFill,
        Size = UDim2.fromScale(1, 1),
        ScrollBarImageColor3 = "accent",
    })
    New("UIListLayout", { Parent = scroll })

    local function render()
        for name, row in configs.Rows do
            local selected = name == configs.Selected
            row.Button.BackgroundTransparency = selected and 0 or 1
            Library:Bind(row.Label, "TextColor3", selected and "accent_soft" or "text")
        end
    end

    function configs:Select(name)
        self.Selected = name
        render()
    end

    -- Re-reads the config folder.
    function configs:Reload()
        for _, row in self.Rows do
            Utility.Destroy(row.Button)
        end
        table.clear(self.Rows)

        local names = Library:ListConfigs()
        for index, name in names do
            local button = New("TextButton", {
                Parent = scroll,
                Size = UDim2.new(1, 0, 0, 16),
                BackgroundColor3 = "selected",
                LayoutOrder = index,
            })
            local label = Utility.Text("panel_text", { Parent = button, Size = UDim2.fromScale(1, 1), Text = name })
            self.Rows[name] = { Button = button, Label = label }
            Utility.Connect(button.MouseButton1Click, function()
                configs:Select(name)
            end)
        end
        if not (self.Selected and self.Rows[self.Selected]) then
            self.Selected = names[1]
        end
        render()
    end

    function configs:Load()
        if self.Selected and Library:LoadConfigFile(self.Selected) then
            Library:Notify({ "loaded config ", { self.Selected } })
        end
    end

    -- Saves the current settings as a new config; the name defaults to the next free number.
    function configs:Save(name)
        local saved = Library:SaveConfig(name)
        self.Selected = saved
        self:Reload()
        Library:Notify({ "saved config ", { saved } })
        return saved
    end

    function configs:Rewrite()
        if self.Selected then
            Library:SaveConfig(self.Selected)
            Library:Notify({ "rewrote config ", { self.Selected } })
        end
    end

    function configs:Delete()
        if self.Selected then
            local name = self.Selected
            Library:DeleteConfig(name)
            self.Selected = nil
            self:Reload()
            Library:Notify({ "deleted config ", { name } })
        end
    end

    local function row(offset, list)
        local holder = New("Frame", {
            Parent = container,
            Position = UDim2.new(0, 3, 1, offset),
            Size = UDim2.new(1, -6, 0, 24),
            BackgroundTransparency = 1,
        })
        for index, properties in list do
            local slotPosition, slotSize = ButtonSlot(index, #list, 6)
            CreateButton(holder, properties, slotPosition, slotSize, "panel_text")
        end
    end

    row(-87, {
        { Name = "Load", Callback = function() configs:Load() end },
        { Name = "Save", Callback = function() configs:Save() end },
    })
    row(-57, {
        { Name = "Delete", Callback = function() configs:Delete() end },
        { Name = "Rewrite", Callback = function() configs:Rewrite() end },
    })
    row(-27, {
        { Name = "Refresh", Callback = function() configs:Reload() end },
    })

    SetupPanel(configs, cfg)
    configs:Reload()
    self.Components.Configs = configs
    return configs
end

--// Lua window and script api ---------------------------------------------------

local Scripts = {} -- name -> running script api

-- The environment handed to scripts run from the lua window (also `...`).
local function CreateScriptApi(name)
    local api = { name = name, library = Library, flags = Library.Flags, options = Library.Options }
    local cleanup = {}

    function api.get(flag)
        return Library.Flags[flag]
    end

    -- Sets a flag through its element so the menu and callbacks stay in sync.
    function api.set(flag, value)
        local option = Library.Options[flag]
        if option and option.Set then
            option:Set(value)
            return true
        end
        return false
    end

    -- api.on("flag", fn) listens to a flag; "render", "heartbeat", "open",
    -- "config" and "unload" are library events.
    function api.on(event, callback)
        local disconnect
        if event == "render" or event == "heartbeat" then
            local signal = event == "render" and RunService.RenderStepped or RunService.Heartbeat
            local connection = Utility.Connect(signal, callback)
            disconnect = function()
                connection:Disconnect()
            end
        elseif event == "open" or event == "config" or event == "unload" then
            local signal = event == "open" and Library.OpenChanged
                or event == "config" and Library.ConfigLoaded
                or Library.Unloading
            local connection = signal:Connect(callback)
            disconnect = connection.Disconnect
        else
            disconnect = Library:OnChanged(event, callback)
        end
        table.insert(cleanup, disconnect)
        return disconnect
    end

    -- Connects to any Roblox signal; disconnected when the script is unloaded.
    function api.connect(signal, callback)
        local connection = signal:Connect(callback)
        table.insert(cleanup, function()
            connection:Disconnect()
        end)
        return connection
    end

    function api.notify(parts, duration)
        return Library:Notify(parts, duration)
    end

    function api.window()
        return Library.Components.Menu
    end

    -- Returns the menu tab with this name, creating it on first use.
    function api.tab(tabName)
        local menu = Library.Components.Menu
        if not menu then
            return nil
        end
        for _, tab in menu.Tabs do
            if tab.Name == tabName then
                return tab
            end
        end
        return menu:Tab({ Name = tabName })
    end

    function api.unload()
        for _, disconnect in cleanup do
            pcall(disconnect)
        end
        table.clear(cleanup)
        if Scripts[name] == api then
            Scripts[name] = nil
        end
    end

    return api
end

-- Library:ScriptApi("name") builds the same api for code you load yourself.
function Library:ScriptApi(name)
    return CreateScriptApi(name or "script")
end

-- Compiles and runs lua source. Returns true, or false and the error message.
-- Running a script again under the same name unloads the previous run first.
function Library:RunScript(source, name)
    name = name or "script"
    if not Env.loadstring then
        return false, "loadstring is not available in this environment"
    end
    local chunk, problem = Env.loadstring(source, "=" .. name)
    if not chunk then
        return false, tostring(problem)
    end

    if Scripts[name] then
        Scripts[name].unload()
    end
    local api = CreateScriptApi(name)
    Scripts[name] = api

    if setfenv and getfenv then
        -- scripts see `api`, `library`, `flags` and the api functions as globals,
        -- on top of whatever the executor gives a loadstring chunk
        local base = getfenv(chunk)
        local environment = setmetatable({ api = api, library = Library, flags = Library.Flags }, {
            __index = function(_, key)
                local value = api[key]
                if value ~= nil then
                    return value
                end
                return base[key]
            end,
        })
        pcall(setfenv, chunk, environment)
    end

    task.spawn(function()
        local ok, message = xpcall(chunk, function(err)
            return tostring(err)
        end, api)
        if not ok then
            warn(string.format("[%s] %s: %s", Library.Name, name, message))
            Library:Notify({ { "lua error: ", rgb(220, 80, 80) }, message }, 6)
        end
    end)
    return true
end

function Library:Lua(properties)
    self:Load()
    local cfg = Options(properties, {
        name = "lua",
        size = Vector2.new(449, 283),
        position = Vector2.new(891, 503),
        placeholder = "-- lua here",
        file = "main", -- saved as <Folder>/scripts/<file>.lua
    })
    cfg.id = "lua"

    local frame, container = PanelWindow("Lua", cfg, { { "outline" } }, { { "panel_inline" } }, "page", 27, 6, 4)
    local lua = setmetatable({ Frame = frame, File = cfg.file }, Panel)

    local _, editor = Utility.Box({
        Parent = container,
        Position = fromOffset(3, 2),
        Size = UDim2.new(1, -6, 1, -30),
    }, { { "border" }, { "button_outline" } }, "white")
    Utility.Gradient(editor, { "editor_top", "list_bottom" })
    New("Frame", { Parent = editor, Size = UDim2.new(0, 15, 1, 0), BackgroundColor3 = "gutter" })

    local scroll = New("ScrollingFrame", {
        Parent = editor,
        Size = UDim2.fromScale(1, 1),
        ScrollBarImageColor3 = "accent",
        AutomaticCanvasSize = Enum.AutomaticSize.XY,
        ScrollingDirection = Enum.ScrollingDirection.XY,
    })
    local highlight = New("Frame", {
        Parent = scroll,
        Position = fromOffset(15, 0),
        Size = UDim2.new(1, -15, 0, 14),
        BackgroundColor3 = "editor_line",
    })
    local numbers = Utility.Text("panel_text", {
        Parent = scroll,
        Position = fromOffset(2, 0),
        Size = fromOffset(13, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        RichText = true,
        TextXAlignment = Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 2,
    })
    local input = Utility.Text("panel_text", {
        Class = "TextBox",
        Parent = scroll,
        Position = fromOffset(16, 0),
        Size = UDim2.new(1, -20, 0, 16), -- grows with the script; long lines scroll sideways
        AutomaticSize = Enum.AutomaticSize.XY,
        MultiLine = true,
        TextWrapped = false,
        TextXAlignment = Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        PlaceholderText = cfg.placeholder,
        PlaceholderColor3 = "placeholder",
        ZIndex = 2,
        Stroke = false,
    })
    lua.Input = input

    local line = 1

    local function refresh()
        local _, breaks = string.gsub(input.Text, "\n", "")
        local size = (Library.Text.panel_text or Library.Text.text).Size
        local pitch = size + 1
        -- always number every visible row, like an editor
        local rows = math.max(breaks + 1, math.floor(editor.AbsoluteSize.Y / Library.Scale / pitch))

        local cursor = input.CursorPosition
        if cursor and cursor > 0 then
            local _, before = string.gsub(string.sub(input.Text, 1, cursor - 1), "\n", "")
            line = before + 1
        end
        line = math.clamp(line, 1, breaks + 1)

        local accent = Utility.RichColor(Library:GetColor("accent_soft"))
        local out = table.create(rows)
        for index = 1, rows do
            out[index] = index == line and string.format('<font color="%s">%d</font>', accent, index) or tostring(index)
        end
        numbers.Text = table.concat(out, "\n")

        local bounds = numbers.TextBounds.Y / Library.Scale
        if bounds > 0 then
            pitch = bounds / rows
        end
        highlight.Position = fromOffset(15, math.floor((line - 1) * pitch + 0.5))
        highlight.Size = UDim2.new(1, -15, 0, math.max(1, math.floor(pitch + 0.5) - 2))
    end

    Utility.Connect(input:GetPropertyChangedSignal("Text"), refresh)
    Utility.Connect(input:GetPropertyChangedSignal("CursorPosition"), refresh)
    Library.ThemeChanged:Connect(refresh)

    function lua:GetText()
        return input.Text
    end

    function lua:SetText(text)
        input.Text = tostring(text or "")
    end

    function lua:Execute()
        local ok, message = Library:RunScript(input.Text, self.File)
        if not ok then
            warn(string.format("[%s] %s", Library.Name, message))
            Library:Notify({ { "lua error: ", rgb(220, 80, 80) }, message }, 6)
        end
        return ok, message
    end

    local function path(name)
        return Library.Folder .. "/scripts/" .. (name or lua.File) .. ".lua"
    end

    function lua:Save(name)
        Files.MakeFolder(Library.Folder .. "/scripts")
        local saved = Files.Write(path(name), input.Text)
        Library:Notify(saved and { "saved script ", { name or self.File } } or "this executor has no filesystem")
        return saved
    end

    function lua:Load(name)
        local source = Files.Read(path(name))
        if source then
            self.File = name or self.File
            self:SetText(source)
            return true
        end
        return false
    end

    local buttons = New("Frame", {
        Parent = container,
        Position = UDim2.new(0, 3, 1, -25),
        Size = UDim2.new(1, -6, 0, 20),
        BackgroundTransparency = 1,
    })
    for index, properties in {
        { Name = "Execute", Callback = function() lua:Execute() end },
        { Name = "Save", Callback = function() lua:Save() end },
    } do
        local slotPosition, slotSize = ButtonSlot(index, 2, 5)
        CreateButton(buttons, properties, slotPosition, slotSize, "panel_text")
    end

    SetupPanel(lua, cfg)
    lua:Load()
    refresh()
    if cfg.autoexecute and input.Text ~= "" then
        lua:Execute()
    end
    self.Components.Lua = lua
    return lua
end

--// Theme window ----------------------------------------------------------------

-- A ready-made settings window: every theme colour, presets, and the options
-- of whichever hud pieces exist when it is created (so create it last).
function Library:ThemeWindow(properties)
    local cfg = Options(properties, {
        name = "theme",
        size = Vector2.new(387, 400),
        position = Vector2.new(598, 150),
        visible = false,
    })
    cfg.id = "theme"
    local components = self.Components
    local window = self:Window(cfg)

    local colors = window:Tab({ Name = "colors" })
    local pickers = {}
    local half = math.ceil(#self.ThemeOrder / 2)
    local palette = colors:Section({ Name = "palette", Side = "left" })
    local surfaces = colors:Section({ Name = "surfaces", Side = "right" })

    local names = {}
    for name in self.Presets do
        table.insert(names, name)
    end
    table.sort(names)
    palette:Dropdown({
        Name = "preset",
        Options = names,
        Default = "rainworld",
        Save = false,
        Callback = function(name)
            local preset = Library.Presets[name]
            if not preset then
                return
            end
            for key, color in preset do
                if pickers[key] then
                    pickers[key]:Set(color)
                end
            end
        end,
    })
    for index, key in self.ThemeOrder do
        local section = index <= half and palette or surfaces
        pickers[key] = section:Colorpicker({
            Name = (string.gsub(key, "_", " ")),
            Default = self.Theme[key],
            Flag = "theme_" .. key,
            Callback = function(color)
                if Library.Theme[key] ~= color then
                    Library:SetTheme(key, color)
                end
            end,
        })
    end

    local interface = window:Tab({ Name = "interface" })
    local menu = interface:Section({ Name = "menu", Side = "left", Height = "auto" })
    menu:Keybind({
        Name = "menu key",
        Default = self.ToggleKey,
        Flag = "ui_menu_key",
        Hidden = true,
        Modes = false,
        KeyChanged = function(key)
            Library.ToggleKey = key or Enum.KeyCode.RightShift
        end,
    })
    menu:Slider({
        Name = "ui scale",
        Min = 50,
        Max = 200,
        Step = 5,
        Default = math.floor(self.Scale * 100 + 0.5),
        Suffix = "%",
        Flag = "ui_scale",
        Callback = function(value)
            Library:SetScale(value / 100)
        end,
    })
    menu:Dropdown({
        Name = "text",
        Options = { "figma", "crisp" },
        Default = "figma",
        Flag = "ui_text",
        Callback = function(mode)
            -- "crisp" renders ProggyClean at its native pixel size
            local crisp = mode == "crisp"
            local sizes = { tab = 10, section = 8, text = 9, button = 10, hud = 10, watermark = 9 }
            for role, size in sizes do
                Library:SetText(role, { Size = crisp and 12 or size })
            end
        end,
    })

    if components.Dock then
        menu:Dropdown({
            Name = "dock",
            Options = { "top", "float" },
            Default = string.lower(components.Dock.Mode),
            Flag = "ui_dock",
            Callback = function(mode)
                components.Dock:SetMode(mode)
            end,
        })
    end

    if components.Watermark then
        local section = interface:Section({ Name = "watermark", Side = "left", Height = "auto" })
        section:Dropdown({
            Name = "animation",
            Options = { "none", "bounce", "wave", "shine" },
            Default = string.lower(components.Watermark.Brand.Animation),
            Flag = "ui_watermark_animation",
            Callback = function(animation)
                components.Watermark:SetAnimation(animation)
            end,
        })
        section:Slider({
            Name = "speed",
            Min = 0.25,
            Max = 3,
            Step = 0.25,
            Default = components.Watermark.Brand.Speed,
            Suffix = "x",
            Flag = "ui_watermark_speed",
            Callback = function(speed)
                components.Watermark.Brand.Speed = speed
            end,
        })
    end

    if components.Hitlogs then
        local logs = components.Hitlogs
        local section = interface:Section({ Name = "hitlogs", Side = "left" })
        section:Dropdown({
            Name = "side",
            Options = { "left", "right", "top", "bottom" },
            Default = string.lower(logs.Side),
            Flag = "ui_hitlog_side",
            Callback = function(side)
                logs:SetSide(side)
            end,
        })
        section:Dropdown({
            Name = "animation",
            Options = { "slide", "bounce", "back", "fade" },
            Default = string.lower(logs.Animation),
            Flag = "ui_hitlog_animation",
            Callback = function(animation)
                logs:SetAnimation(animation)
            end,
        })
        section:Slider({
            Name = "duration",
            Min = 1,
            Max = 10,
            Step = 0.5,
            Default = logs.Duration,
            Suffix = "s",
            Flag = "ui_hitlog_duration",
            Callback = function(duration)
                logs.Duration = duration
            end,
        })
        section:Button({
            Name = "test",
            Callback = function()
                logs:Add({ "hit ", { "player" }, " in the ", { "head" }, " for ", { "100" } })
            end,
        })
    end

    if components.KeybindList then
        local list = components.KeybindList
        local section = interface:Section({ Name = "keybinds", Side = "right", Height = "auto" })
        section:Dropdown({
            Name = "show",
            Options = { "all", "active" },
            Default = string.lower(list.Mode),
            Flag = "ui_keybind_mode",
            Callback = function(mode)
                list:SetMode(mode)
            end,
        })
        section:Toggle({
            Name = "show keys",
            Default = list.ShowKeys,
            Flag = "ui_keybind_keys",
            Callback = function(show)
                list:SetShowKeys(show)
            end,
        })
        -- off: the key follows the row colour; on: it gets its own
        local keyColor
        local colourKeys = section:Toggle({
            Name = "colour keys",
            Default = list.KeyColor ~= nil,
            Flag = "ui_keybind_color_keys",
            Callback = function(enabled)
                list:SetKeyColor(enabled and keyColor and keyColor.Value or nil)
            end,
        })
        keyColor = colourKeys:Colorpicker({
            Default = self:GetColor(list.KeyColor or "accent_text"),
            Flag = "ui_keybind_key_color",
            Callback = function(color)
                if colourKeys.Value then
                    list:SetKeyColor(color)
                end
            end,
        })
        section:Colorpicker({
            Name = "active colour",
            Default = self:GetColor(list.ActiveColor),
            Flag = "ui_keybind_active_color",
            Callback = function(color)
                -- untouched, the highlight keeps following the theme
                if color ~= Library:GetColor(list.ActiveColor) then
                    list:SetActiveColor(color)
                end
            end,
        })
    end

    if components.TargetHud then
        local hud = components.TargetHud
        local section = interface:Section({ Name = "target hud", Side = "right" })
        section:Dropdown({
            Name = "position",
            Options = { "static", "attached" },
            Default = string.lower(hud.Mode),
            Flag = "ui_target_mode",
            Callback = function(mode)
                hud:SetMode(mode)
            end,
        })
        for _, element in { "Avatar", "Name", "Role", "Stats", "Health", "Armor" } do
            section:Toggle({
                Name = string.lower(element),
                Default = hud.Elements[element],
                Flag = "ui_target_" .. string.lower(element),
                Callback = function(enabled)
                    hud:SetElement(element, enabled)
                end,
            })
        end
    end

    components.Theme = window
    return window
end

--// Mobile toggle and unload ----------------------------------------------------

-- A small draggable button that opens and closes the menu on touch devices.
function Library:MobileButton(properties)
    self:Load()
    local cfg = Options(properties, { name = string.upper(string.sub(self.Name, 1, 1)), position = Vector2.new(12, 120) })
    cfg.id = "mobile"
    local position = ToVector2(cfg.position, Vector2.new(12, 120))

    local frame, fill = Utility.Box({
        Name = "Toggle",
        Parent = self.Root,
        Position = fromOffset(position.X, position.Y),
        Size = fromOffset(34, 34),
        ZIndex = 9,
    }, { { "outline", 2 }, { "inline" } }, "background")
    Utility.Text("title", { Parent = fill, Size = UDim2.fromScale(1, 1), Text = cfg.name, TextColor3 = "accent_text" })
    local button = New("TextButton", { Parent = frame, Size = UDim2.fromScale(1, 1), ZIndex = 2 })
    local panel = setmetatable({ Frame = frame }, Panel)

    -- a tap toggles the menu, a drag only moves the button
    local pressedAt
    Utility.Connect(button.InputBegan, function(input)
        if IsPress(input) then
            pressedAt = panel:GetPosition()
        end
    end)
    Utility.Connect(button.MouseButton1Click, function()
        if pressedAt and (panel:GetPosition() - pressedAt).Magnitude > 4 then
            return
        end
        Library:SetOpen(not Library.Open)
    end)
    Utility.Drag(button, frame)

    SetupPanel(panel, cfg, true)
    self.Components.MobileButton = panel
    return panel
end

function Library:Unload()
    if self.Unloaded then
        return
    end
    self.Unloaded = true
    self.Unloading:Fire()
    for _, api in table.clone(Scripts) do
        api.unload()
    end
    for _, connection in self.Connections do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(self.Connections)
    for _, gui in { self.Gui, self.OverlayGui } do
        if gui then
            gui:Destroy()
        end
    end
    table.clear(self.Keybinds)
    table.clear(self.Panels)
end

return Library
