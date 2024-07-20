const std = @import("std");

/// Returned cache path is owned by caller and should be managed.
pub fn get_cache(allocator: std.mem.Allocator) ![]const u8 {
    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();
    const home_dir = envmap.get("HOME").?;
    const cache_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ home_dir, "/.cache" });
    return cache_dir;
}
