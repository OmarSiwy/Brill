const std = @import("std");

const types = @import("types.zig");

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
    const runtime_dir = wm.init.environ_map.get("XDG_RUNTIME_DIR") orelse return;
    const focused_output_idx = wm.focused_output_idx orelse return;
    const output = wm.output_list.items[focused_output_idx];

    var state: [output.workspace_list.len]u8 = undefined;
    for (output.workspace_list, 0..) |workspace, idx| {
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
    std.Io.Dir.cwd().writeFile(wm.init.io, .{
        .sub_path = path,
        .data = &state,
    }) catch return;
}
