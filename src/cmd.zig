const std = @import("std");
const hf_hub = @import("hf_hub");
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var args_iterator = std.process.args();
    _ = args_iterator.next();
    const repo_id = args_iterator.next() orelse {
        std.debug.print("Repo Id should be provided in args\n", .{});
        return error.ArgError;
    };

    const file = args_iterator.next() orelse {
        std.debug.print("File Name should be provided in args\n", .{});
        return error.ArgError;
    };

    std.debug.print("Started Downloading {s} from the repo {s}\n", .{ file, repo_id });

    var repo = try hf_hub.Repo.init_with_repo_id(repo_id, allocator);
    const path = try repo.download(file, allocator);

    std.debug.print("File has been downloaded at: {s}\n", .{path});
}
