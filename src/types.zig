const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

pub const WindowManager = struct {
    init: std.process.Init,
    registry: *wayland.client.wl.Registry,
    river_window_manager: ?*river.WindowManagerV1,
    river_xkb_bindings: ?*river.XkbBindingsV1,
    river_layer_shell: ?*river.LayerShellV1,
    river_libinput_config: ?*river.LibinputConfigV1,
    river_seat: ?*river.SeatV1,
    output_list: std.ArrayList(Output),
    focused_output_idx: ?usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },
    status: Status,
    config: Config,
    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        action: KeybindingAction,
    }),
    pointer_binding_list: std.ArrayList(struct {
        river_pointer_binding: *river.PointerBindingV1,
        action: PointerAction,
    }),

    pub fn deinit(self: *WindowManager, config_is_parsed: bool) void {
        if (config_is_parsed) std.zon.parse.free(self.init.gpa, self.config);

        self.xkb_binding_list.deinit(self.init.gpa);
        self.pointer_binding_list.deinit(self.init.gpa);

        for (self.output_list.items) |*output|
            for (&output.workspace_list) |*workspace|
                workspace.window_list.deinit(self.init.gpa);
        self.output_list.deinit(self.init.gpa);

        self.registry.destroy();
    }
};

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    is_fullscreen: bool,
    is_closing: bool,
    floating: Rectangle,
    current: Rectangle,
    start: ?Rectangle,
    finish: ?Rectangle,
};

pub const Workspace = struct {
    window_list: std.ArrayList(Window) = .empty,
    focused_window_idx: ?usize = null,
    is_floating: bool = false,

    pub fn redistributeProportions(self: *Workspace) void {
        const n = self.window_list.items.len;
        if (n == 0) return;
        const equal: f32 = 1.0 / @as(f32, @floatFromInt(n));
        for (self.window_list.items) |*w| w.proportion = equal;
    }
};

pub const Output = struct {
    river_output: *river.OutputV1,
    river_layer_shell_output: ?*river.LayerShellOutputV1,
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
    rectangle: Rectangle,
    non_exclusive: Rectangle,
    is_removed: bool,
};

pub const Rectangle = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Status = union(enum) {
    layout: void,
    animation: i64,
    pointer_action: PointerAction,
    setup_bindings: void,
    exit: void,
    none: void,
};

pub const Config = struct {
    vertical_gap: i32 = 9,
    horizontal_gap: i32 = 9,
    default_window_width: f32 = 0.5,
    center_focused_window: enum { never, always, single } = .never,
    no_csd: bool = true,
    equal_width_tiling: bool = false,
    animation_duration: u32 = 200,
    border: Border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    },
    cursor: ?struct { theme: [:0]const u8, size: u32 } = null,
    spawn_at_startup: []const []const []const u8 = &.{},
    input: struct {
        tap: enum { disabled, enabled } = .enabled,
        tap_button_map: enum { lrm, lmr } = .lrm,
        natural_scroll: enum { disabled, enabled } = .enabled,
        click_method: enum { none, button_areas, clickfinger } = .clickfinger,
        clickfinger_button_map: enum { lrm, lmr } = .lrm,
    } = .{},
    keybindings: []const Keybinding = &default_keybindings,
    pointer_bindings: []const PointerBinding = &default_pointer_bindings,
};

const Border = struct { width: u8, focused_color: Color, unfocused_color: Color };

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32,

    pub fn toRiverColor(self: Color) struct { r: u32, g: u32, b: u32, a: u32 } {
        var r: f32 = @floatFromInt(self.r);
        var g: f32 = @floatFromInt(self.g);
        var b: f32 = @floatFromInt(self.b);

        r = self.a * r / 255;
        g = self.a * g / 255;
        b = self.a * b / 255;

        const max: f64 = @floatFromInt(std.math.maxInt(u32));
        return .{
            .r = @trunc(r * max),
            .g = @trunc(g * max),
            .b = @trunc(b * max),
            .a = @trunc(self.a * max),
        };
    }
};

const Keybinding = struct {
    key: [:0]const u8,
    modifiers: river.SeatV1.Modifiers,
    action: KeybindingAction,
};

pub const KeybindingAction = union(enum) {
    close_window: void,
    toggle_fullscreen: void,
    adjust_window_width: f32,
    set_window_width: f32,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    toggle_workspace_floating: void,
    focus_workspace_above: void,
    focus_workspace_below: void,
    focus_workspace_previous: void,
    focus_workspace_number: usize,
    move_window_to_workspace_above: void,
    move_window_to_workspace_below: void,
    move_window_to_workspace_number: usize,
    focus_output_left: void,
    focus_output_right: void,
    focus_output_above: void,
    focus_output_below: void,
    move_window_to_output_left: void,
    move_window_to_output_right: void,
    move_window_to_output_above: void,
    move_window_to_output_below: void,
    exit: void,
    reload_config: void,
    spawn: []const []const u8,
};

const PointerBinding = struct {
    button: Button,
    modifiers: river.SeatV1.Modifiers,
    action: PointerAction,
};

const Button = enum(u32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
};

const PointerAction = enum { move_window, resize_window };

pub const default_keybindings = [_]Keybinding{
    .{ .key = "q", .modifiers = .{ .mod4 = true }, .action = .close_window },
    .{ .key = "f", .modifiers = .{ .mod4 = true }, .action = .toggle_fullscreen },

    .{ .key = "minus", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = -0.1 } },
    .{ .key = "equal", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = 0.1 } },
    .{ .key = "BackSpace", .modifiers = .{ .mod4 = true }, .action = .{ .set_window_width = 0.5 } },

    .{ .key = "Left", .modifiers = .{ .mod4 = true }, .action = .focus_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true }, .action = .focus_window_right },
    .{ .key = "Left", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_right },

    .{ .key = "v", .modifiers = .{ .mod4 = true }, .action = .toggle_workspace_floating },

    .{ .key = "Up", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_below },
    .{ .key = "grave", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_previous },

    .{ .key = "1", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 10 } },

    .{ .key = "Up", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 10 } },

    .{ .key = "h", .modifiers = .{ .mod4 = true }, .action = .focus_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true }, .action = .focus_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true }, .action = .focus_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true }, .action = .focus_output_below },

    .{ .key = "h", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_below },

    .{ .key = "Escape", .modifiers = .{ .mod4 = true }, .action = .exit },
    .{ .key = "r", .modifiers = .{ .mod4 = true }, .action = .reload_config },

    .{ .key = "t", .modifiers = .{ .mod4 = true }, .action = .{ .spawn = &[_][]const u8{"alacritty"} } },

    .{
        .key = "XF86AudioRaiseVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05+", "--limit", "1.0" } },
    },
    .{
        .key = "XF86AudioLowerVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05-" } },
    },
    .{
        .key = "XF86AudioMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } },
    },
    .{
        .key = "XF86AudioMicMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" } },
    },
};

const default_pointer_bindings = [_]PointerBinding{
    .{ .button = .left, .modifiers = .{ .mod4 = true }, .action = .move_window },
    .{ .button = .right, .modifiers = .{ .mod4 = true }, .action = .resize_window },
};
