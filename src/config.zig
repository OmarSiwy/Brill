const std = @import("std");

const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };
pub var is_parsed: bool = false;

pub fn load(init: std.process.Init) types.Config {
    xdg_config_home: {
        const config = find(Location.XDG_CONFIG_HOME, init) catch |err| {
            std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});
            break :xdg_config_home;
        };
        return config orelse break :xdg_config_home;
    }

    const config = find(Location.HOME, init) catch |err| {
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});
        return .{};
    };
    return config orelse return .{};
}

fn find(location: Location, init: std.process.Init) !?types.Config {
    const env = init.environ_map.get(@tagName(location)) orelse return null;

    const path = switch (location) {
        .XDG_CONFIG_HOME => try std.fs.path.join(init.gpa, &.{
            env,
            "rill",
            "config.zon",
        }),
        .HOME => try std.fs.path.join(init.gpa, &.{
            env,
            ".config",
            "rill",
            "config.zon",
        }),
    };
    defer init.gpa.free(path);

    const content = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        path,
        init.gpa,
        std.Io.Limit.unlimited,
        std.mem.Alignment.@"16",
        0,
    );
    defer init.gpa.free(content);

    const config = try std.zon.parse.fromSliceAlloc(
        types.Config,
        init.gpa,
        content,
        null,
        .{},
    );

    is_parsed = true;
    return config;
}

test "validate default config file" {
    const fields = std.meta.fields(types.Config);

    const config_struct = types.Config{};
    const config_file: types.Config = @import("default_config");

    inline for (fields) |field| {
        const has_field = @hasField(@TypeOf(@import("default_config")), field.name);
        if (!has_field) {
            std.debug.print("Default config file is missing field '{s}'\n", .{field.name});
            try std.testing.expect(has_field);
        }

        const struct_value = @field(config_struct, field.name);
        const file_value = @field(config_file, field.name);

        std.testing.expectEqualDeep(struct_value, file_value) catch |err| {
            std.debug.print("Value of '{s}' doesn't match\n", .{field.name});
            return err;
        };
    }
}
