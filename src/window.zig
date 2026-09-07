const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    const output_idx = wm.focused_output_idx orelse return;

    if (event == .dimensions) {
        for (layout.pending_windows.items, 0..) |window, idx| {
            if (window != river_window) continue;

            const output = &wm.output_list.items[output_idx];
            add(wm.allocator, window, output, wm.getConfig()) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = layout.pending_windows.swapRemove(idx);

            layout.update(wm.output_list, wm.getConfig());
            wm.status = .layout;
            wm.river_window_manager.?.manageDirty();
            return;
        }
    }

    for (wm.output_list.items) |*output| {
        for (output.workspace_list.items) |*workspace| {
            const window_idx = workspace.focused_window_idx orelse continue;

            for (workspace.window_list.items, 0..) |*window, idx| {
                if (window.river_window != river_window) continue;

                switch (event) {
                    .closed => {
                        if (workspace.window_list.items.len == 1) {
                            workspace.focused_window_idx = null;
                        } else if (idx <= window_idx and window_idx != 0) {
                            workspace.focused_window_idx = window_idx - 1;
                        }

                        _ = workspace.window_list.orderedRemove(idx);
                        river_window.destroy();

                        if (wm.getConfig().equal_width_tiling)
                            workspace.redistributeProportions();
                    },
                    .fullscreen_requested => {
                        if (wm.status != .none) return;
                        window.is_fullscreen = true;
                    },
                    .exit_fullscreen_requested => {
                        if (wm.status != .none) return;
                        window.is_fullscreen = false;
                    },
                    else => return,
                }

                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;

                return;
            }
        }
    }
}

fn add(
    allocator: std.mem.Allocator,
    river_window: *river.WindowV1,
    output: *types.Output,
    config: types.Config,
) !void {
    const non_exclusive = output.non_exclusive orelse output.rect;
    const h_gap = config.horizontal_gap;
    const v_gap = config.vertical_gap;

    const base_width: f32 = @floatFromInt(non_exclusive.width - h_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);

    const initial_rect = types.Rectangle{
        .width = width_with_gap - h_gap,
        .height = non_exclusive.height - 2 * v_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + v_gap,
    };

    const window = types.Window{
        .river_window = river_window,
        .river_node = try river_window.getNode(),
        .proportion = config.default_window_width,
        .should_close = false,
        .is_maximized = false,
        .is_fullscreen = false,
        .floating_rect = initial_rect,
        .current_rect = initial_rect,
        .start_rect = null,
        .finish_rect = null,
    };

    const workspace = &output.workspace_list.items[output.focused_workspace_idx];
    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = idx + 1;

    try workspace.window_list.insert(allocator, window_idx, window);
    workspace.focused_window_idx = window_idx;

    if (config.equal_width_tiling)
        workspace.redistributeProportions();
}
