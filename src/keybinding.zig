const std = @import("std");

const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn setupKeybindings(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
) !void {
    for (wm.xkb_binding_list.items) |binding| binding.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.getConfig().keybindings) |keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = try xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            @intFromEnum(keysym),
            keybinding.modifiers,
        );

        try wm.xkb_binding_list.append(
            allocator,
            .{ .river_xkb_binding = xkb_binding, .action = keybinding.action },
        );
        xkb_binding.setListener(*types.WindowManager, xkbBindingListener, wm);
        xkb_binding.enable();
    }
}

fn parseKey(key: [:0]const u8) ?xkbcommon.Keysym {
    const keysym = xkbcommon.Keysym.fromName(key, .case_insensitive);
    if (keysym != .NoSymbol) return keysym;
    return null;
}

test "validate default keybindings" {
    for (types.default_keybindings) |keybinding| {
        if (parseKey(keybinding.key) == null) {
            std.debug.print("Keysym '{s}' is not valid\n", .{keybinding.key});
        }
        try std.testing.expect(parseKey(keybinding.key) != null);
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    if (wm.status == .pointer_action) return;
    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != xkb_binding) continue;

        switch (event) {
            .pressed => {
                const action = binding.action;
                // if we are in passthrough mode and we are not trying to toggle it then
                // go ahead and forego checking the action.
                if (wm.is_passthrough and action != .toggle_passthrough) continue;

                keybindingPressed(
                    wm.allocator,
                    wm.io,
                    wm.environ_map,
                    action,
                    wm,
                ) catch |err| {
                    std.debug.print("Keybinding's action failed: {}\n", .{err});
                };
            },
            else => {},
        }
        return;
    }
}

fn keybindingPressed(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: std.process.Environ.Map,
    action: types.KeybindingAction,
    wm: *types.WindowManager,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list.items[workspace_idx];

    action_switch: switch (action) {
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.should_close = true;
        },
        .toggle_maximize => {
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;
            window.is_maximized = !window.is_maximized;
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
        },
        .adjust_window_width => |increment| {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;

            var proportion = window.proportion;
            if (window.is_maximized) proportion = 1.0;

            const non_exclusive = output.non_exclusive orelse output.rect;
            const h_gap = wm.getConfig().horizontal_gap;
            const base_width: f32 = @floatFromInt(non_exclusive.width - h_gap);
            const width_with_gap: i32 = @trunc(base_width * (proportion + increment));
            if (width_with_gap - h_gap < 2 * wm.getConfig().border.width) return;

            window.is_maximized = false;
            window.proportion = proportion + increment;
        },
        .set_window_width => |proportion| {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;
            window.is_maximized = false;
            window.proportion = proportion;
        },
        .focus_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            workspace.focused_window_idx = window_idx - 1;
        },
        .focus_window_or_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or window_idx == 0) {
                continue :action_switch .focus_output_left;
            }
            continue :action_switch .focus_window_left;
        },
        .focus_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            workspace.focused_window_idx = window_idx + 1;
        },
        .focus_window_or_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .focus_output_right;
            }
            continue :action_switch .focus_window_right;
        },
        .move_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx - 1],
            );
            workspace.focused_window_idx = window_idx - 1;
        },
        .move_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx + 1],
            );
            workspace.focused_window_idx = window_idx + 1;
        },
        .move_window_left_or_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) {
                continue :action_switch .move_window_to_output_left;
            }
            continue :action_switch .move_window_left;
        },
        .move_window_right_or_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .move_window_to_output_right;
            }
            continue :action_switch .move_window_right;
        },
        .toggle_workspace_floating => workspace.is_floating = !workspace.is_floating,
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                output.focused_workspace_idx - 1,
            );
        },
        .focus_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                output.focused_workspace_idx + 1,
            );
        },
        .focus_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .focus_output_above;
            }
            continue :action_switch .focus_workspace_above;
        },
        .focus_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .focus_output_below;
            }
            continue :action_switch .focus_workspace_below;
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;
            try focusWindowToWorkspace(
                wm,
                null,
                previous.output_idx,
                previous.workspace_idx,
            );
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > output.workspace_list.items.len) return;
            if (workspace_idx == number - 1) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                number - 1,
            );
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx - 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                workspace_idx - 1,
            );
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx + 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                workspace_idx + 1,
            );
        },
        .move_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .move_window_to_output_above;
            }
            continue :action_switch .move_window_to_workspace_above;
        },
        .move_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .move_window_to_output_below;
            }
            continue :action_switch .move_window_to_workspace_below;
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or
                number > output.workspace_list.items.len or
                number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                number - 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                number - 1,
            );
        },
        .send_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx - 1,
            );
        },
        .send_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx + 1,
            );
        },
        .send_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .send_window_to_output_above;
            }
            continue :action_switch .send_window_to_workspace_above;
        },
        .send_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .send_window_to_output_below;
            }
            continue :action_switch .send_window_to_workspace_below;
        },
        .send_window_to_workspace_number => |number| {
            if (number == 0 or
                number > output.workspace_list.items.len or
                number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                number - 1,
            );
        },
        .focus_output_left => {
            const target = getOutputLeft(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_right => {
            const target = getOutputRight(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_above => {
            const target = getOutputAbove(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_below => {
            const target = getOutputBelow(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .move_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputLeft(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputRight(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputAbove(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputBelow(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputLeft(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputRight(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputAbove(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputBelow(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .spawn => |command| {
            const pid = std.posix.system.fork();
            if (pid < 0) {
                return error.ForkFailed;
            } else if (pid == 0) {
                _ = try std.process.spawn(io, .{ .argv = command });
                std.process.exit(0);
            }
            _ = std.posix.system.waitpid(pid, null, 0);
            return;
        },
        .reload_config => {
            const old_config = wm.config;
            const new_config = config.load(allocator, io, environ_map) orelse return;

            wm.config = new_config;

            if (old_config) |cfg|
                std.zon.parse.free(wm.allocator, cfg);

            if (wm.getConfig().cursor) |cursor| {
                wm.river_seat.?.setXcursorTheme(cursor.theme, cursor.size);
            }
            layout.update(wm.output_list, wm.getConfig());

            wm.status = .setup_bindings;
            return;
        },
        .toggle_passthrough => wm.is_passthrough = !wm.is_passthrough,
        .exit => {
            wm.status = .exit;
            return;
        },
    }

    layout.update(wm.output_list, wm.getConfig());
    wm.status = .layout;
}

// Move a window to a target workspace.
fn moveWindowToWorkspace(
    allocator: std.mem.Allocator,
    window_idx: usize,
    workspace: *types.Workspace,
    target_workspace: *types.Workspace,
) !usize {
    const window = workspace.window_list.orderedRemove(window_idx);

    if (workspace.window_list.items.len == 0) {
        workspace.focused_window_idx = null;
    } else if (window_idx != 0) {
        workspace.focused_window_idx = window_idx - 1;
    }

    var target_window_idx: usize = 0;
    if (target_workspace.focused_window_idx) |idx| target_window_idx = idx + 1;

    try target_workspace.window_list.insert(allocator, target_window_idx, window);
    target_workspace.focused_window_idx = target_window_idx;
    return target_window_idx;
}

// Sends a window to a workspace found on an output.
fn sendWindowToWorkspace(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
    window_idx: usize,
    target_output_idx: usize,
    target_workspace_idx: usize,
) !usize {
    const output_idx = wm.focused_output_idx orelse return 0;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list.items[workspace_idx];

    // ensure the target output is available
    if (target_output_idx >= wm.output_list.items.len) return 0;
    const target_output = &wm.output_list.items[target_output_idx];

    // ensure the target workspace is available
    if (target_workspace_idx >= target_output.workspace_list.items.len) return 0;
    const target_workspace = &target_output.workspace_list.items[target_workspace_idx];

    // move the window to the target workspace
    const target_window_idx = try moveWindowToWorkspace(
        allocator,
        window_idx,
        workspace,
        target_workspace,
    );
    return target_window_idx;
}

// Sets the focus of an output, workspace, and optionally the window.
fn focusWindowToWorkspace(
    wm: *types.WindowManager,
    target_window_idx: ?usize,
    target_output_idx: usize,
    target_workspace_idx: ?usize,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;

    // ensure the target output is available
    if (target_output_idx >= wm.output_list.items.len) return;
    const target_output = &wm.output_list.items[target_output_idx];

    // ensure the target workspace is available
    const next_workspace_idx: usize = target_workspace_idx orelse target_output.focused_workspace_idx;
    if (next_workspace_idx >= target_output.workspace_list.items.len) return;
    const target_workspace = &target_output.workspace_list.items[next_workspace_idx];

    var next_window_idx: ?usize = target_window_idx orelse target_workspace.focused_window_idx;
    if (next_window_idx) |idx| {
        if (idx >= target_workspace.window_list.items.len) {
            // if the window index is out of bounds then select the last one
            next_window_idx = target_workspace.window_list.items.len - 1;
        }
    }

    // set the focus
    wm.focused_output_idx = target_output_idx;
    target_output.focused_workspace_idx = next_workspace_idx;
    target_workspace.focused_window_idx = next_window_idx;

    // set the previous
    wm.previous_workspace = .{
        .output_idx = output_idx,
        .workspace_idx = workspace_idx,
    };
}

// TargetOutput represents the next output to target.
const TargetOutput = struct {
    output: *types.Output,
    index: usize,
};

// Get the output above the currently focused output.
fn getOutputAbove(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = target_output.rect.y + target_output.rect.height;
        if (edge != output.rect.y) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output below the currently focused output.
fn getOutputBelow(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = output.rect.y + target_output.rect.height;
        if (edge != target_output.rect.y) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output left of the currently focused output.
fn getOutputLeft(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = target_output.rect.x + target_output.rect.width;
        if (edge != output.rect.x) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output right of the currently focused output.
fn getOutputRight(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = output.rect.x + target_output.rect.width;
        if (edge != target_output.rect.x) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}
