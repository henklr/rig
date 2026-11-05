-- Hyprland 0.57 only reads Lua: hyprland.conf is gone.
-- API reference: /usr/share/hypr/stubs/hl.meta.lua
-- Wiki:          https://wiki.hypr.land/configuring/
-- Check first:   Hyprland --verify-config

local home = os.getenv("HOME")
local mod = "SUPER"

local terminal = "alacritty"
local launcher = "fuzzel"
local browser = "brave"
local files = "nemo"

local background = 0xff141416


---------------
---- SETUP ----
---------------

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})

hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "18")
hl.env("HYPRCURSOR_SIZE", "18")


-----------------
---- COPILOT ----
-----------------

-- Claude lives in a scratchpad over everything else: SUPER + A shows and hides
-- it, and closing Claude just means the next SUPER + A starts a new one.
-- It runs in ~/rig, so the system's own config is what it works on by default.
local copilot_class = "rig.copilot"
local copilot_cmd = terminal .. " --class=" .. copilot_class
    .. " --working-directory=" .. home .. "/rig -e claude"

local function copilot_running()
    for _, window in ipairs(hl.get_windows()) do
        if window.class == copilot_class then
            return true
        end
    end
    return false
end

local function toggle_copilot()
    if not copilot_running() then
        hl.exec_cmd(copilot_cmd)
    end
    hl.dispatch(hl.dsp.workspace.toggle_special("copilot"))
end

hl.window_rule({
    name      = "copilot-scratchpad",
    match     = { class = "^rig\\.copilot$" },
    workspace = "special:copilot silent",
})

hl.workspace_rule({ workspace = "special:copilot", gaps_out = 48 })


------------------
---- FLOATING ----
------------------

-- Super + T turns a workspace into an ordinary desktop: its windows float, and
-- so do new ones, until the same key tiles them again. New windows need a rule
-- to open at their own size, because a window floated later keeps its tiled size.
local floating_rules = {}

for i = 1, 10 do
    floating_rules[i] = hl.window_rule({
        name    = "floating-workspace-" .. i,
        match   = { workspace = tostring(i) },
        float   = true,
        enabled = false,
    })
end

-- Global, so bin/rig-menu can reach it with hyprctl eval.
function toggle_floating()
    local workspace = hl.get_active_workspace()
    local rule = workspace and floating_rules[workspace.id]
    if not rule then
        return
    end

    local floating = not rule:is_enabled()
    local action = floating and "enable" or "disable"
    rule:set_enabled(floating)
    for _, window in ipairs(workspace:get_windows()) do
        local at, size = window.at, window.size
        hl.dispatch(hl.dsp.window.float({ action = action, window = window }))
        if floating then -- Hyprland centers it, partly under the bar
            hl.dispatch(hl.dsp.window.resize({ x = size.x, y = size.y, window = window }))
            hl.dispatch(hl.dsp.window.move({ x = at.x, y = at.y, window = window }))
        end
    end
    hl.notification.create({ text = floating and "Flydende vinduer" or "Tiling", timeout = 1500 })
end

hl.on("window.move_to_workspace", function(window, workspace)
    local rule = floating_rules[workspace.id]
    if rule and rule:is_enabled() then
        hl.dispatch(hl.dsp.window.float({ action = "enable", window = window }))
    end
end)


-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("wl-paste --watch cliphist store")
    hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme prefer-dark")

    -- The installer leaves this flag once: the first login lands in Claude.
    local flag = home .. "/.local/state/rig/first-boot"
    local file = io.open(flag, "r")
    if file then
        file:close()
        os.remove(flag)
        toggle_copilot()
    end
end)


----------------------
---- LOOK AND FEEL ----
----------------------

hl.config({
    general = {
        gaps_in     = 3,
        gaps_out    = 6,
        border_size = 1,
        resize_on_border = true,
        col = {
            active_border   = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },
        layout = "dwindle",
    },

    decoration = {
        rounding         = 6,
        active_opacity   = 0.975,
        inactive_opacity = 0.75,
        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },
        blur = {
            enabled  = true,
            size     = 5,
            passes   = 3,
            vibrancy = 0.2,
        },
    },

    animations = { enabled = false },

    dwindle = { preserve_split = true },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        disable_splash_rendering = true,
        background_color        = background,
    },

    input = {
        follow_mouse   = 1,
        sensitivity    = 0.5,
        natural_scroll = true,
        accel_profile  = "flat",
        touchpad       = { natural_scroll = true },
    },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })


--------------
---- KEYS ----
--------------

hl.bind(mod .. " + A", toggle_copilot)
hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + Space", hl.dsp.exec_cmd(launcher))
hl.bind(mod .. " + B", hl.dsp.exec_cmd(browser))
hl.bind(mod .. " + F", hl.dsp.exec_cmd(files))
hl.bind(mod .. " + L", hl.dsp.exec_cmd("hyprlock"))
hl.bind(mod .. " + M", hl.dsp.exec_cmd("rig-menu"))

hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + T", toggle_floating)
hl.bind(mod .. " + P", hl.dsp.window.pseudo())
hl.bind(mod .. " + J", hl.dsp.layout("togglesplit"))
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())

hl.bind(mod .. " + left", hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up", hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down", hl.dsp.focus({ direction = "down" }))

hl.bind(mod .. " + SHIFT + left", hl.dsp.window.swap({ direction = "left" }))
hl.bind(mod .. " + SHIFT + right", hl.dsp.window.swap({ direction = "right" }))
hl.bind(mod .. " + SHIFT + up", hl.dsp.window.swap({ direction = "up" }))
hl.bind(mod .. " + SHIFT + down", hl.dsp.window.swap({ direction = "down" }))

for i = 1, 10 do
    local key = i % 10 -- workspace 10 is on the 0 key
    hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mod .. " + S", hl.dsp.workspace.toggle_special("magic"))
hl.bind(mod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("Print", hl.dsp.exec_cmd([[grim -g "$(slurp)" - | wl-copy]]))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd(
    [[mkdir -p ~/Pictures && grim ~/Pictures/screenshot-$(date +%F-%H%M%S).png]]))
hl.bind(mod .. " + SHIFT + V", hl.dsp.exec_cmd(
    "cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))

local volume = "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ "
local repeats = { locked = true, repeating = true }
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(volume .. "5%+"), repeats)
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(volume .. "5%-"), repeats)
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"), repeats)
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"), repeats)
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })


---------------
---- RULES ----
---------------

hl.window_rule({
    name   = "rig-update",
    match  = { class = "^rig\\.update$" },
    float  = true,
    center = true,
    size   = { 900, 560 },
})

hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})



-----------------
---- MACHINE ----
-----------------

-- Last, so it can override anything above: keyboard layout, monitors, GPU.
-- Written by the installer, ignored by git.
pcall(require, "machine")
