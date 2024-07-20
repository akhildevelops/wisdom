const fs = @import("std").fs;
const builtin = @import("builtin");
const std = @import("std");
const utils = @import("utils.zig");
const RepoType = enum { model, dataset, space };

const HUGGINGFACE_URL_TEMPLATE = "https://huggingface.co/{repo_id}/resolve/{revision}/{filename}";

const Metadata = struct { size: usize, commit_hash: []const u8, etag: []const u8 };
var server_header_buffer: [16 * 1024]u8 = undefined;
const Repo = struct {
    repo_id: []const u8,
    repo_type: RepoType,
    revision: []const u8,
    cache: Cache,
    client: std.http.Client,
    const Self = @This();
    fn deinit(self: *Self) void {
        self.client.deinit();
        self.cache.deinit();
    }

    fn init_with_repo_id(repo_id: []const u8, allocator: std.mem.Allocator) !Self {
        return Self.init_with_repo_id_cache(repo_id, try Cache.init(null, allocator), allocator);
    }
    fn init_with_repo_id_cache(repo_id: []const u8, cache: Cache, allocator: std.mem.Allocator) !Self {
        return .{ .repo_id = repo_id, .client = .{ .allocator = allocator }, .cache = cache, .repo_type = RepoType.model, .revision = "main" };
    }

    fn repo_path(self: Self, allocator: std.mem.Allocator) !RepoPath {
        return self.cache.repo_path(self, allocator);
    }

    fn get_url(self: Self, file_name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var url: []const u8 = HUGGINGFACE_URL_TEMPLATE;
        inline for ([_][]const u8{ "{repo_id}", "{revision}" }) |template_var| {
            url = try std.mem.replaceOwned(u8, allocator, url, template_var, @field(self, template_var[1 .. template_var.len - 1]));
        }
        url = try std.mem.replaceOwned(u8, allocator, url, "{filename}", file_name);
        return url;
    }

    fn download(self: *Self, filename: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        // Extract Metadata of the file and download
        const metadata = try self.meta_data(filename, allocator);
        const url = try self.get_url(filename, allocator);
        const uri = try std.Uri.parse(url);
        var request = try self.client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer });
        defer request.deinit();
        try request.send();
        try request.finish();
        try request.wait();

        // Write data to a temp file
        const tmp_path_file = try self.cache.tmp_file(allocator);
        const file = try self.cache.path.createFile(tmp_path_file, .{ .truncate = true });
        const reader = request.reader();
        const writer = file.writer();
        var pipe = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
        try pipe.pump(reader, writer);

        // Move to temp file to blob path
        const blob_path = try self.cache.blob_path(self.*, metadata.etag, allocator);
        try std.fs.rename(self.cache.path, tmp_path_file, self.cache.path, blob_path);

        // Symlink the hash to file
        const pointer_path = try self.cache.pointer_path(self.*, metadata.commit_hash, filename, allocator);
        try self.cache.path.symLink(blob_path, pointer_path, .{});

        // write commit_hash
        const commit_hash_path = try self.cache.ref_path(self.*, allocator);
        var cfile = try self.cache.path.createFile(commit_hash_path, .{ .truncate = true });
        try cfile.writeAll(metadata.commit_hash);
        return pointer_path;
    }

    fn meta_data(self: *Self, file_name: []const u8, allocator: std.mem.Allocator) !Metadata {
        const url = try self.get_url(file_name, allocator);
        const uri = try std.Uri.parse(url);

        var req = try self.client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        var headers = req.response.iterateHeaders();
        var commit_hash: ?[]const u8 = null;
        var _x_etag: ?[]const u8 = null;
        var etag: ?[]const u8 = null;
        var size: ?usize = null;
        while (headers.next()) |header| {
            if (std.mem.eql(u8, header.name, "X-Repo-Commit")) {
                commit_hash = try allocator.dupe(u8, header.value);
            }
            if (std.mem.eql(u8, header.name, "x-Linked-ETag")) {
                _x_etag = try allocator.dupe(u8, header.value);
            }
            if (std.mem.eql(u8, header.name, "ETag")) {
                // Avoids doube quotes
                etag = try allocator.dupe(u8, header.value[1 .. header.value.len - 1]);
            }
            if (std.mem.eql(u8, header.name, "Content-Length")) {
                size = try std.fmt.parseInt(usize, header.value, 10);
            }
        }
        etag = _x_etag orelse etag;
        if (size == null or commit_hash == null or etag == null) {
            return error.MetadataIsNull;
        }

        return .{ .size = size.?, .commit_hash = commit_hash.?, .etag = etag.? };
    }
};

const RepoPath = struct {
    repo: Repo,
    dir: fs.Dir,
    const Self = @This();

    fn get(self: Self, file: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        _ = self.dir.openFile(file, .{}) catch |e| {
            switch (e) {
                .FileNotFound => return null,
                else => return e,
            }
        };
        const dir_path = try self.dir.realpathAlloc(allocator, ".");
        const full_path = try std.mem.concat(allocator, u8, &[_][]const u8{ dir_path, file });
        return full_path;
    }
};

const Cache = struct {
    path: fs.Dir,
    const Self = @This();

    fn init(path: ?[]const u8, allocator: std.mem.Allocator) !Self {
        switch (builtin.os.tag) {
            .linux => {
                var dir: std.fs.Dir = undefined;
                if (path) |_path| {
                    dir = try fs.openDirAbsolute(_path, .{ .iterate = true });
                } else {
                    const cache_dir = try utils.get_cache(allocator);
                    const huggingface_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ cache_dir, "/huggingface/hub" });
                    fs.makeDirAbsolute(huggingface_dir) catch {};
                    dir = try fs.openDirAbsolute(huggingface_dir, .{ .iterate = true });
                }

                return .{ .path = dir };
            },
            else => {
                @compileError("This lib doesn't support other than linux");
            },
        }
    }

    fn deinit(self: *Self) void {
        self.path.close();
    }

    fn blob_path(self: Self, repo: Repo, etag: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const repo_prefix = try self._repo_prefix(repo, allocator);
        const blobs_dir = try std.fmt.allocPrint(allocator, "{s}/blobs", .{repo_prefix});
        self.path.makePath(blobs_dir) catch {};
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ blobs_dir, etag });
    }

    fn pointer_path(self: Self, repo: Repo, commit_hash: []const u8, file_name: ?[]const u8, allocator: std.mem.Allocator) ![]const u8 {
        const repo_prefix = try self._repo_prefix(repo, allocator);
        const snapshots_dir = try std.fmt.allocPrint(allocator, "{s}/snapshots", .{repo_prefix});
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ snapshots_dir, commit_hash });
        self.path.makePath(path) catch {};
        if (file_name) |file| {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, file });
        } else {
            return path;
        }
    }

    fn tmp_file(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        self.path.makeDir("tmp") catch {};
        var Xoshiro = std.Random.DefaultPrng.init(0);
        const random_gen = Xoshiro.random();
        var file_name: [10]u8 = undefined;
        inline for (0..file_name.len) |index| {
            file_name[index] = random_gen.intRangeAtMost(u8, 65, 89);
        }
        const op = try allocator.alloc(u8, 10);
        std.mem.copyBackwards(u8, op, &file_name);
        return try std.fmt.allocPrint(allocator, "tmp/{s}", .{op});
    }

    fn _repo_prefix(_: Self, repo: Repo, allocator: std.mem.Allocator) ![]const u8 {
        const prefix: []const u8 = switch (repo.repo_type) {
            .model => "models",
            .dataset => "dataset",
            .space => "space",
        };
        const subpath = try std.fmt.allocPrint(allocator, "{s}--{s}", .{ prefix, repo.repo_id });

        return std.mem.replaceOwned(u8, allocator, subpath, "/", "--");
    }

    fn ref_path(self: Self, repo: Repo, allocator: std.mem.Allocator) ![]const u8 {
        const repo_prefix = try self._repo_prefix(repo, allocator);
        const ref_dir = try std.fmt.allocPrint(allocator, "{s}/refs", .{repo_prefix});
        self.path.makePath(ref_dir) catch {};
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_dir, repo.revision });
    }

    fn repo_path(self: Self, repo: Repo, allocator: std.mem.Allocator) !?RepoPath {
        const commit_hash_file = try self.ref_path(repo, allocator);

        const file = self.path.openFile(commit_hash_file, .{}) catch |e| {
            switch (e) {
                .FileNotFound => return null,
                else => return e,
            }
        };
        defer file.close();

        const hash = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        const _pointer_path = try self.pointer_path(hash, null, allocator);

        const repo_dir = self.path.openDir(_pointer_path, .{}) catch |e| {
            switch (e) {
                .FileNotFound => return null,
                else => return e,
            }
        };

        return .{ .repo = repo, .dir = repo_dir };
    }
};

pub fn download_artifacts(model_id: []const u8, revision: ?[]const u8, allocator: std.mem.Allocator) ![]const u8 {
    const cache_dir = try Cache.init(null, allocator);
    var rev: []const u8 = undefined;
    if (revision == null) {
        rev = "main";
    } else {
        rev = revision.?;
    }
    const repo: Repo = .{ .allocator = allocator, .repo_id = model_id, .repo_type = RepoType.model, .revision = rev, .cache = cache_dir };
    const repo_path = try cache_dir.repo_path(repo, allocator);
    if (repo_path) |path| {
        const config_path = try path.get("config.json", allocator);
        if (config_path) |_| {} else {
            repo.download("config.json");
        }
    } else {}
}

test "RepoID" {
    var AA = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = AA.allocator();
    var repo = try Repo.init_with_repo_id("THUDM/codegeex4-all-9b", allocator);
    repo.deinit();
    AA.deinit();
}

test "RepoMeta" {
    var AA = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer AA.deinit();
    const allocator = AA.allocator();
    var repo = try Repo.init_with_repo_id("THUDM/codegeex4-all-9b", allocator);
    defer repo.deinit();
    const metadata = try repo.meta_data("config.json", allocator);
    try std.testing.expectEqual(metadata.size, 1473);
    try std.testing.expectEqualStrings("6ee90cf42fbd24807825b5ff6bed9830a5a4cfb2", metadata.commit_hash);
    try std.testing.expectEqualStrings("c04609d634dafb54519278f3fb3d36e7c26c4f54", metadata.etag);
}

test "RepoDownload" {
    var AA = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer AA.deinit();
    const allocator = AA.allocator();
    var repo = try Repo.init_with_repo_id("THUDM/codegeex4-all-9b", allocator);
    defer repo.deinit();
    const path = try repo.download("config.json", allocator);
    _ = path;
}
