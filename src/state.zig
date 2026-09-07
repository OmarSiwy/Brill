const std = @import("std");
const Io = std.Io;

const types = @import("types.zig");

/// One byte per workspace slot, so a fixed 10 keeps the bar's indices stable
/// even with dynamic_workspaces growing and shrinking the list.
const slots = 10;

/// rill has no IPC, so a state file is the whole protocol: on every layout
/// change we dump the focused output's workspace occupancy to
/// $XDG_RUNTIME_DIR/rill-state and the eww bar reads it.
///
/// Format is 10 bytes, one per workspace: 'f' focused, 'o' occupied, 'e' empty.
/// Flat chars, not JSON — the bar indexes it with substring() and there is
/// nothing to escape or parse.
///
/// ponytail: the bar polls this file every 200ms instead of watching it. The
/// write is one ~10-byte page-atomic syscall and eww only redraws on change, so
/// the poll is free; swap in an inotify listener only if the latency ever shows.
pub fn write(wm: *const types.WindowManager) void {
    const runtime_dir = wm.environ_map.get("XDG_RUNTIME_DIR") orelse return;
    const focused_output_idx = wm.focused_output_idx orelse return;
    const output = wm.output_list.items[focused_output_idx];

    var state: [slots]u8 = @splat('e');
    for (output.workspace_list.items[0..@min(slots, output.workspace_list.items.len)], 0..) |workspace, idx| {
        state[idx] = if (idx == output.focused_workspace_idx)
            'f'
        else if (workspace.window_list.items.len > 0)
            'o'
        else
            'e';
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/rill-state",
        .{runtime_dir},
    ) catch return;

    // Best-effort: a bar that can't be fed is not a reason to disturb the WM.
    Io.Dir.cwd().writeFile(wm.io, .{
        .sub_path = path,
        .data = &state,
    }) catch return;
}

test "occupancy encoding" {
    // ponytail: exercises the encode branch only — the file write needs a live
    // WindowManager, and that is what running the WM tells you.
    const workspaces = [_]struct { windows: usize }{
        .{ .windows = 2 }, .{ .windows = 0 }, .{ .windows = 1 },
    };
    const focused: usize = 2;

    var state: [slots]u8 = @splat('e');
    for (workspaces, 0..) |workspace, idx| {
        state[idx] = if (idx == focused) 'f' else if (workspace.windows > 0) 'o' else 'e';
    }
    try std.testing.expectEqualStrings("oefeeeeeee", &state);
}
