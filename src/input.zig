const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

pub fn setup(wm: *types.WindowManager) void {
    const libinput_config = wm.river_libinput_config orelse {
        std.debug.print("river_libinput_config_v1 not available\n", .{});
        return;
    };
    libinput_config.setListener(*types.WindowManager, libinputConfigListener, wm);
}

fn libinputConfigListener(
    _: *river.LibinputConfigV1,
    event: river.LibinputConfigV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .libinput_device => |dev_event| {
            dev_event.id.setListener(*types.WindowManager, libinputDeviceListener, wm);
        },
        else => {},
    }
}

fn libinputDeviceListener(
    device: *river.LibinputDeviceV1,
    event: river.LibinputDeviceV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .tap_support => |ev| {
            if (ev.finger_count == 0) return;
            const state: river.LibinputDeviceV1.TapState = switch (wm.config.input.tap) {
                .disabled => .disabled,
                .enabled => .enabled,
            };
            const result = device.setTap(state) catch return;
            result.setListener(?*anyopaque, libinputResultListener, null);
        },
        .natural_scroll_support => |ev| {
            if (ev.supported == 0) return;
            const state: river.LibinputDeviceV1.NaturalScrollState = switch (wm.config.input.natural_scroll) {
                .disabled => .disabled,
                .enabled => .enabled,
            };
            const result = device.setNaturalScroll(state) catch return;
            result.setListener(?*anyopaque, libinputResultListener, null);
        },
        .click_method_support => |ev| {
            const method: river.LibinputDeviceV1.ClickMethod = switch (wm.config.input.click_method) {
                .none => .none,
                .button_areas => .button_areas,
                .clickfinger => if (ev.methods.clickfinger) .clickfinger else .button_areas,
            };
            const result = device.setClickMethod(method) catch return;
            result.setListener(?*anyopaque, libinputResultListener, null);
        },
        .tap_button_map_default => {
            const map: river.LibinputDeviceV1.TapButtonMap = switch (wm.config.input.tap_button_map) {
                .lrm => .lrm,
                .lmr => .lmr,
            };
            const result = device.setTapButtonMap(map) catch return;
            result.setListener(?*anyopaque, libinputResultListener, null);
        },
        .clickfinger_button_map_default => {
            const map: river.LibinputDeviceV1.ClickfingerButtonMap = switch (wm.config.input.clickfinger_button_map) {
                .lrm => .lrm,
                .lmr => .lmr,
            };
            const result = device.setClickfingerButtonMap(map) catch return;
            result.setListener(?*anyopaque, libinputResultListener, null);
        },
        .removed => device.destroy(),
        else => {},
    }
}

fn libinputResultListener(
    _: *river.LibinputResultV1,
    event: river.LibinputResultV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .success => {},
        .unsupported => std.debug.print("rill: libinput config unsupported by device\n", .{}),
        .invalid => std.debug.print("rill: libinput config invalid\n", .{}),
    }
}
