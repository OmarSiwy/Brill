const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };

pub fn load(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
) ?*types.Config {
    if(find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});

    if(find(allocator, io, .HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});

    return null;
}

fn find(
    allocator: Allocator,
    io: Io,
    location: Location,
    environ_map: std.process.Environ.Map,
) !*types.Config {
    const env = environ_map.get(@tagName(location)) orelse return error.FileNotFound;

    const path = switch (location) {
        .XDG_CONFIG_HOME => try Io.Dir.path.join(allocator, &.{
            env,
            "rill",
            "config.zon",
        }),
        .HOME => try Io.Dir.path.join(allocator, &.{
            env,
            ".config",
            "rill",
            "config.zon",
        }),
    };
    defer allocator.free(path);

    const content = try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .unlimited,
        .@"16",
        0,
    );
    defer allocator.free(content);

    const config = try std.zon.parse.fromSliceAlloc(
        *types.Config,
        allocator,
        content,
        null,
        .{},
    );

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
