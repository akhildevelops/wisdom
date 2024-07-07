const std = @import("std");
const zensor = @import("zensor");
pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us, built since {d}\n", .{ "codebase", zensor.add(5, 5) });
}
