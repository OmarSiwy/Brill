const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const input = @import("input.zig");
const keybinding = @import("keybinding.zig");
const layout = @import("layout.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const window = @import("window.zig");

pub fn main(init: std.process.Init) !void {
    // No PR_SET_PDEATHSIG here. It signals on *parent* death, and the parent is
    // whatever shell launched us — with river's documented `rill &` in
    // ~/.config/river/init that shell exits immediately, killing rill on
    // startup. Outliving river is already impossible two ways over: the
    // dispatch loop below exits when the wl connection drops, and river
    // SIGTERMs its whole init process group on shutdown.
    const display = try wayland.client.wl.Display.connect(null);
    defer display.disconnect();

    const cfg = config.load(init.gpa, init.io, init.environ_map.*);

    var wm = types.WindowManager{
        .allocator = init.gpa,
        .io = init.io,
        .environ_map = init.environ_map.*,
        .registry = try display.getRegistry(),
        .river_window_manager = null,
        .river_xkb_bindings = null,
        .river_layer_shell = null,
        .river_libinput_config = null,
        .river_seat = null,
        .output_list = .empty,
        .focused_output_idx = null,
        .previous_workspace = null,
        .config = cfg,
        .xkb_binding_list = .empty,
        .pointer_binding_list = .empty,
        .status = .none,
    };
    defer wm.deinit();

    wm.registry.setListener(*types.WindowManager, registryListener, &wm);
    _ = display.roundtrip();

    const window_manager = wm.river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(*types.WindowManager, windowManagerListener, &wm);

    const loaded_config = wm.getConfig();
    for (loaded_config.spawn_at_startup) |command| {
        _ = std.process.spawn(wm.io, .{ .argv = command }) catch |err| {
            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
        };
    }

    var workspaces_to_create: i32 = 10;
    if (loaded_config.dynamic_workspaces) {
        workspaces_to_create = 1;
    }
    for (wm.output_list.items) |*my_output| {
        while (workspaces_to_create > 0) : (workspaces_to_create -= 1) {
            const workspace = types.Workspace{
                .window_list = .empty,
                .focused_window_idx = null,
                .is_floating = false,
            };
            try my_output.workspace_list.append(wm.allocator, workspace);
        }
    }

    while (true) {
        const status = display.dispatch();
        if (status != .SUCCESS) {
            std.debug.print("Window manager stopped with status: {}\n", .{status});
            break;
        }
        if (wm.status == .animation) window_manager.manageDirty();
    }
}

fn registryListener(
    registry: *wayland.client.wl.Registry,
    event: wayland.client.wl.Registry.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                wm.river_window_manager =
                    registry.bind(global.name, river.WindowManagerV1, 4) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                wm.river_xkb_bindings =
                    registry.bind(global.name, river.XkbBindingsV1, 1) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                wm.river_layer_shell =
                    registry.bind(global.name, river.LayerShellV1, 1) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_libinput_config_v1")) {
                wm.river_libinput_config =
                    registry.bind(global.name, river.LibinputConfigV1, 1) catch null;
                input.setup(wm);
            }
        },
        .global_remove => {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .output => |output_event| {
            output.add(wm.allocator, output_event.id, wm) catch |err|
                std.debug.print("Failed to add output: {}\n", .{err});
        },
        .seat => |seat_event| {
            wm.river_seat = seat_event.id;
            seat_event.id.setListener(*types.WindowManager, seat.seatListener, wm);

            if (wm.getConfig().cursor) |cursor| {
                seat_event.id.setXcursorTheme(cursor.theme, cursor.size);
            }
            wm.status = .setup_bindings;

            const layer_shell = wm.river_layer_shell orelse {
                std.debug.print("Failed to find layer shell\n", .{});
                return;
            };
            const layer_shell_seat = layer_shell.getSeat(seat_event.id) catch {
                std.debug.print("Failed to get layer shell seat\n", .{});
                return;
            };
            layer_shell_seat.setListener(*types.WindowManager, seat.layerShellSeatListener, wm);
        },
        .window => |window_event| {
            layout.pending_windows.append(wm.allocator, window_event.id) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            window_event.id.setListener(*types.WindowManager, window.windowListener, wm);
            wm.status = .layout;
        },
        .manage_start => {
            manage(wm.allocator, wm.io, wm);
            window_manager.manageFinish();
        },
        .render_start => window_manager.renderFinish(),
        .finished => window_manager.destroy(),
        else => {},
    }
}

fn manage(allocator: Allocator, io: Io, wm: *types.WindowManager) void {
    const focused_output_idx = wm.focused_output_idx orelse return;
    const river_seat = wm.river_seat orelse {
        std.debug.print("Failed to find seat\n", .{});
        return;
    };

    switch (wm.status) {
        .layout => {
            layout.apply(
                allocator,
                wm.output_list,
                focused_output_idx,
                wm.getConfig(),
                river_seat,
            );
            wm.status = .{
                .animation = Io.Clock.awake.now(io).toMilliseconds(),
            };
            // Every workspace focus, window open and window close routes through
            // .layout, so this one call keeps the bar's indicator honest.
            state.write(wm);
        },
        .animation => |start_time| {
            wm.status = animation.apply(
                wm.output_list,
                focused_output_idx,
                wm.getConfig(),
                start_time,
                Io.Clock.awake.now(io).toMilliseconds(),
            );
        },
        .pointer_action => {
            river_seat.opStartPointer();
            seat.pointerAction(wm.output_list, focused_output_idx, wm.getConfig());
        },
        .setup_bindings => {
            keybinding.setupKeybindings(allocator, wm) catch |err| {
                std.debug.print("Failed to setup keybindings: {}\n", .{err});
            };
            seat.setupPointerBindings(allocator, wm) catch |err| {
                std.debug.print("Failed to setup pointer bindings: {}\n", .{err});
            };

            wm.status = .layout;
            wm.river_window_manager.?.manageDirty();
        },
        .exit => {
            wm.deinit();
            wm.river_window_manager.?.exitSession();
        },
        .none => river_seat.opEnd(),
    }
}

test {
    std.testing.refAllDecls(@This());
}
