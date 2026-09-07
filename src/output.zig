const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn add(
    allocator: std.mem.Allocator,
    river_output: *river.OutputV1,
    wm: *types.WindowManager,
) !void {
    for (wm.output_list.items, 0..) |*output, idx| {
        if (output.river_output != null) continue;

        output.river_output = river_output;
        output.river_layer_shell_output = getLayerShellOutput(river_output, wm);

        wm.focused_output_idx = idx;
        river_output.setListener(*types.WindowManager, outputListener, wm);
        return;
    }

    var workspaces: std.ArrayList(types.Workspace) = .empty;
    var number_of_workspaces: i32 = 10;
    if (wm.getConfig().dynamic_workspaces) {
        number_of_workspaces = 1;
    }

    while (number_of_workspaces > 0) : (number_of_workspaces -= 1) {
        const workspace = types.Workspace{
            .window_list = .empty,
            .focused_window_idx = null,
            .is_floating = false,
        };
        try workspaces.append(allocator, workspace);
    }

    const output = types.Output{
        .river_output = river_output,
        .river_layer_shell_output = getLayerShellOutput(river_output, wm),
        .workspace_list = workspaces,
        .focused_workspace_idx = 0,
        .rect = undefined,
        .non_exclusive = null,
    };
    try wm.output_list.append(allocator, output);

    wm.focused_output_idx = wm.output_list.items.len - 1;
    river_output.setListener(*types.WindowManager, outputListener, wm);
}

fn getLayerShellOutput(
    river_output: *river.OutputV1,
    wm: *types.WindowManager,
) ?*river.LayerShellOutputV1 {
    const layer_shell = wm.river_layer_shell orelse {
        std.debug.print("Failed to find layer shell\n", .{});
        return null;
    };
    const layer_shell_output = layer_shell.getOutput(river_output) catch {
        std.debug.print("Failed to get layer shell output\n", .{});
        return null;
    };

    layer_shell_output.setListener(*types.WindowManager, layerShellOutputListener, wm);
    return layer_shell_output;
}

fn outputListener(
    river_output: *river.OutputV1,
    event: river.OutputV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.output_list.items, 0..) |*output, idx| {
        if (output.river_output != river_output) continue;

        switch (event) {
            .dimensions => |dimensions| {
                output.rect.width = dimensions.width;
                output.rect.height = dimensions.height;
            },
            .position => |position| {
                output.rect.x = position.x;
                output.rect.y = position.y;
            },
            .removed => {
                river_output.destroy();
                output.river_output = null;

                const focused = wm.focused_output_idx orelse return;
                if (wm.output_list.items.len == 1) {
                    wm.focused_output_idx = null;
                } else if (idx <= focused) {
                    wm.focused_output_idx = @max(focused - 1, 0);
                }

                const previous_workspace = wm.previous_workspace orelse return;
                if (previous_workspace.output_idx == idx) {
                    wm.previous_workspace = null;
                } else if (idx <= previous_workspace.output_idx) {
                    wm.previous_workspace.?.output_idx -= 1;
                }

                wm.status = .layout;
            },
            else => {},
        }
        return;
    }
}

fn layerShellOutputListener(
    layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.output_list.items) |*output| {
        if (output.river_layer_shell_output != layer_shell_output) continue;

        switch (event) {
            .non_exclusive_area => |area| {
                output.non_exclusive = .{
                    .width = area.width,
                    .height = area.height,
                    .x = area.x,
                    .y = area.y,
                };
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
            },
        }
        return;
    }
}
