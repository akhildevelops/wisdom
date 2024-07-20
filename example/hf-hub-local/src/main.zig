const hf_hub = @import("hf_hub");
const std = @import("std");

pub fn main() !void {
    //Initializes allocator
    var ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ArenaAllocator.deinit();
    const allocator = ArenaAllocator.allocator();

    //Initializes Repo: vidore/colpali and download tokenizer.model
    var repo = try hf_hub.Repo.init_with_repo_id("vidore/colpali", allocator);
    const path = try repo.download("tokenizer.model", allocator);

    // Prints the downloaded path
    std.debug.print("{s}", .{path});
}
