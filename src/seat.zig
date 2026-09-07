const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn seatListener(
    _: *river.SeatV1,
    event: river.SeatV1.Event,
    wm: *types.WindowManager,
) void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace = output.workspace_list.items[output.focused_workspace_idx];
    const window_idx = workspace.focused_window_idx orelse return;
    const window = &workspace.window_list.items[window_idx];

    switch (event) {
        .window_interaction => |interaction| {
            if (interaction.window == window.river_window) return;

            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                const target_workspace =
                    &target_output.workspace_list.items[target_output.focused_workspace_idx];

                for (target_workspace.window_list.items, 0..) |target_window, target_window_idx| {
                    if (target_window.river_window != interaction.window) continue;

                    wm.focused_output_idx = target_output_idx;
                    target_workspace.focused_window_idx = target_window_idx;

                    if (target_output_idx != output_idx) {
                        wm.previous_workspace = .{
                            .output_idx = output_idx,
                            .workspace_idx = output.focused_workspace_idx,
                        };
                    }

                    layout.update(wm.output_list, wm.getConfig());
                    wm.status = .layout;

                    return;
                }
            }
        },
        .op_delta => |delta| {
            const start = window.start_rect orelse return;

            const output_left = output.rect.x;
            const output_right = output.rect.x + output.rect.width;
            const output_top = output.rect.y;
            const output_bottom = output.rect.y + output.rect.height;

            switch (wm.status.pointer_action) {
                .move_window => {
                    window.floating_rect.x = std.math.clamp(
                        start.x + delta.dx,
                        output_left,
                        output_right - window.current_rect.width,
                    );
                    window.floating_rect.y = std.math.clamp(
                        start.y + delta.dy,
                        output_top,
                        output_bottom - window.current_rect.height,
                    );
                },
                .resize_window => {
                    window.floating_rect.width = std.math.clamp(
                        start.width + delta.dx,
                        0,
                        output_right - window.current_rect.x,
                    );
                    window.floating_rect.height = std.math.clamp(
                        start.height + delta.dy,
                        0,
                        output_bottom - window.current_rect.y,
                    );
                },
            }
            window.current_rect = window.floating_rect;
        },
        .op_release => {
            wm.status = .none;
            window.start_rect = null;
        },
        else => {},
    }
}

pub fn setupPointerBindings(allocator: std.mem.Allocator, wm: *types.WindowManager) !void {
    for (wm.pointer_binding_list.items) |binding| binding.river_pointer_binding.destroy();
    wm.pointer_binding_list.clearRetainingCapacity();

    for (wm.getConfig().pointer_bindings) |binding| {
        const pointer_binding = try wm.river_seat.?.getPointerBinding(
            @intFromEnum(binding.button),
            binding.modifiers,
        );
        try wm.pointer_binding_list.append(
            allocator,
            .{ .river_pointer_binding = pointer_binding, .action = binding.action },
        );
        pointer_binding.setListener(*types.WindowManager, pointerBindingListener, wm);
        pointer_binding.enable();
    }
}

fn pointerBindingListener(
    pointer_binding: *river.PointerBindingV1,
    event: river.PointerBindingV1.Event,
    wm: *types.WindowManager,
) void {
    if (wm.is_passthrough) return;

    for (wm.pointer_binding_list.items) |binding| {
        if (binding.river_pointer_binding != pointer_binding) continue;

        switch (event) {
            .pressed => {
                const output_idx = wm.focused_output_idx orelse return;
                const output = &wm.output_list.items[output_idx];
                const workspace = output.workspace_list.items[output.focused_workspace_idx];
                if (!workspace.is_floating) return;

                const window_idx = workspace.focused_window_idx orelse return;
                const window = &workspace.window_list.items[window_idx];
                if (window.is_fullscreen) return;

                window.start_rect = window.current_rect;
                wm.status = .{ .pointer_action = binding.action };
            },
            else => {},
        }
        return;
    }
}

pub fn layerShellSeatListener(
    _: *river.LayerShellSeatV1,
    event: river.LayerShellSeatV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .focus_none => wm.status = .layout,
        else => {},
    }
}

pub fn pointerAction(
    output_list: std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: types.Config,
) void {
    const output = output_list.items[focused_output_idx];
    const workspace = output.workspace_list.items[output.focused_workspace_idx];
    const window_idx = workspace.focused_window_idx orelse return;
    const window = workspace.window_list.items[window_idx];

    window.river_window.setClipBox(0, 0, 0, 0);

    var border_width = config.border.width;
    if (window.is_fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        @max(0, window.current_rect.width - 2 * border_width),
        @max(0, window.current_rect.height - 2 * border_width),
    );
    window.river_node.setPosition(
        window.current_rect.x + border_width,
        window.current_rect.y + border_width,
    );
}
