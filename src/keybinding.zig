const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn setupKeybindings(wm: *types.WindowManager) !void {
    for (wm.xkb_binding_list.items) |binding| binding.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.config.keybindings) |keybinding| {
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
            wm.init.gpa,
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
        if (parseKey(keybinding.key) == null)
            std.debug.print("Keysym '{s}' is not valid\n", .{keybinding.key});
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
            .pressed => keybindingPressed(binding.action, wm) catch |err|
                std.debug.print("Keybinding's action failed: {}\n", .{err}),
            else => {},
        }
        return;
    }
}

fn keybindingPressed(action: types.KeybindingAction, wm: *types.WindowManager) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list[workspace_idx];

    switch (action) {
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_closing = true;
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

            const gap = wm.config.horizontal_gap;
            const base_width: f32 = @floatFromInt(output.non_exclusive.width - gap);
            const width_with_gap: i32 = @trunc(base_width * (window.proportion + increment));
            if (width_with_gap - gap < 2 * wm.config.border.width) return;

            window.proportion += increment;
        },
        .set_window_width => |proportion| {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            window.proportion = proportion;
        },
        .focus_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            workspace.focused_window_idx = window_idx - 1;
        },
        .focus_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            workspace.focused_window_idx = window_idx + 1;
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
        .toggle_workspace_floating => workspace.is_floating = !workspace.is_floating,
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            output.focused_workspace_idx -= 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_below => {
            if (workspace_idx == 9) return;
            output.focused_workspace_idx += 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;
            wm.focused_output_idx = previous.output_idx;
            const target_output = &wm.output_list.items[previous.output_idx];
            target_output.focused_workspace_idx = previous.workspace_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > 10) return;
            if (workspace_idx == number - 1) return;
            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx - 1];

            try move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                wm.init.gpa,
                wm.config.equal_width_tiling,
            );

            output.focused_workspace_idx = workspace_idx - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == 9) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx + 1];

            try move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                wm.init.gpa,
                wm.config.equal_width_tiling,
            );

            output.focused_workspace_idx = workspace_idx + 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or number > 10 or number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[number - 1];

            try move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                wm.init.gpa,
                wm.config.equal_width_tiling,
            );
            // Send the window away but keep focus on the current workspace.
        },
        .focus_output_left => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_right => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_above => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_below => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    wm.init.gpa,
                    wm.config.equal_width_tiling,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initial_rectangle(target_output.non_exclusive, wm.config);

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    wm.init.gpa,
                    wm.config.equal_width_tiling,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initial_rectangle(target_output.non_exclusive, wm.config);

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    wm.init.gpa,
                    wm.config.equal_width_tiling,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initial_rectangle(target_output.non_exclusive, wm.config);

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    wm.init.gpa,
                    wm.config.equal_width_tiling,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initial_rectangle(target_output.non_exclusive, wm.config);

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .exit => {
            wm.status = .exit;
            return;
        },
        .reload_config => {
            wm.config = config.load(wm.init);
            if (wm.config.cursor) |cursor|
                wm.river_seat.?.setXcursorTheme(cursor.theme, cursor.size);
            input.setup(wm);
            layout.update(wm.output_list, wm.config);

            wm.status = .setup_bindings;
            return;
        },
        .spawn => |command| {
            _ = std.process.spawn(wm.init.io, .{ .argv = command }) catch |err|
                std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
            return;
        },
    }

    layout.update(wm.output_list, wm.config);
    wm.status = .layout;
}

fn move_window_to_workspace(
    window_idx: usize,
    workspace: *types.Workspace,
    target_workspace: *types.Workspace,
    allocator: std.mem.Allocator,
    equal_width_tiling: bool,
) !void {
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

    if (equal_width_tiling) {
        workspace.redistributeProportions();
        target_workspace.redistributeProportions();
    }
}
