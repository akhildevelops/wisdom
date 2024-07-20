const fs = @import("std").fs;
const builtin = @import("builtin");
const std = @import("std");
const utils = @import("utils.zig");
const RepoType = enum { model, dataset, space };

const HUGGINGFACE_URL_TEMPLATE = "https://huggingface.co/{repo_id}/resolve/{revision}/{filename}";

const Metadata = struct { size: usize, commit_hash: []const u8, etag: []const u8, redirect_link: ?[]const u8 };
var server_header_buffer: [16 * 1024]u8 = undefined;
pub const Repo = struct {
    repo_id: []const u8,
    repo_type: RepoType,
    revision: []const u8,
    cache: Cache,
    client: std.http.Client,
    const Self = @This();
    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.cache.deinit();
    }

    pub fn init_with_repo_id(repo_id: []const u8, allocator: std.mem.Allocator) !Self {
        return Self.init_with_repo_id_cache(repo_id, try Cache.init(null, allocator), allocator);
    }
    pub fn init_with_repo_id_cache(repo_id: []const u8, cache: Cache, allocator: std.mem.Allocator) !Self {
        return .{ .repo_id = repo_id, .client = .{ .allocator = allocator }, .cache = cache, .repo_type = RepoType.model, .revision = "main" };
    }

    pub fn repo_path(self: Self, allocator: std.mem.Allocator) !RepoPath {
        return self.cache.repo_path(self, allocator);
    }

    pub fn get_url(self: Self, file_name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var url: []const u8 = HUGGINGFACE_URL_TEMPLATE;
        inline for ([_][]const u8{ "{repo_id}", "{revision}" }) |template_var| {
            url = try std.mem.replaceOwned(u8, allocator, url, template_var, @field(self, template_var[1 .. template_var.len - 1]));
        }
        url = try std.mem.replaceOwned(u8, allocator, url, "{filename}", file_name);
        return url;
    }

    pub fn download(self: *Self, filename: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        // Extract Metadata of the file and download
        const metadata = try self.meta_data(filename, allocator);
        var url: []const u8 = undefined;
        if (metadata.redirect_link) |link| {
            url = link;
        } else {
            url = try self.get_url(filename, allocator);
        }
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
        self.cache.path.deleteFile(pointer_path) catch {};
        const full_pointer_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ try self.cache.path.realpathAlloc(allocator, "."), pointer_path });
        const full_blob_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ try self.cache.path.realpathAlloc(allocator, "."), blob_path });
        try std.fs.symLinkAbsolute(full_blob_path, full_pointer_path, .{});

        // write commit_hash
        const commit_hash_path = try self.cache.ref_path(self.*, allocator);
        var cfile = try self.cache.path.createFile(commit_hash_path, .{ .truncate = true });
        try cfile.writeAll(metadata.commit_hash);
        return full_pointer_path;
    }

    pub fn meta_data(self: *Self, file_name: []const u8, allocator: std.mem.Allocator) !Metadata {
        const url = try self.get_url(file_name, allocator);
        const uri = try std.Uri.parse(url);

        var req = try self.client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer, .redirect_behavior = @enumFromInt(0) });
        defer req.deinit();
        try req.send();
        try req.finish();
        req.wait() catch |e| switch (e) {
            error.TooManyHttpRedirects => {},
            else => return e,
        };

        var headers = req.response.iterateHeaders();
        var commit_hash: ?[]const u8 = null;
        var _x_etag: ?[]const u8 = null;
        var etag: ?[]const u8 = null;
        var size: ?usize = null;
        var redirect_link: ?[]const u8 = null;
        while (headers.next()) |header| {
            if (std.mem.eql(u8, header.name, "X-Repo-Commit")) {
                commit_hash = try allocator.dupe(u8, header.value);
            }
            if (std.mem.eql(u8, header.name, "X-Linked-ETag")) {
                _x_etag = try allocator.dupe(u8, header.value[1 .. header.value.len - 1]);
            }
            if (std.mem.eql(u8, header.name, "ETag")) {
                // Avoids doube quotes
                etag = try allocator.dupe(u8, header.value[1 .. header.value.len - 1]);
            }
            if (std.mem.eql(u8, header.name, "Content-Length")) {
                size = try std.fmt.parseInt(usize, header.value, 10);
            }
            if (std.mem.eql(u8, header.name, "Location") and @intFromEnum(req.response.status) == 302) {
                redirect_link = try allocator.dupe(u8, header.value);
            }
        }

        if (redirect_link) |link| {
            var redirect_req = try self.client.open(.GET, try std.Uri.parse(link), .{ .server_header_buffer = &server_header_buffer, .redirect_behavior = @enumFromInt(0) });
            defer redirect_req.deinit();
            try redirect_req.send();
            try redirect_req.finish();
            try redirect_req.wait();
            var redirect_headers = req.response.iterateHeaders();
            while (redirect_headers.next()) |header| {
                if (std.mem.eql(u8, header.name, "Content-Length")) {
                    size = try std.fmt.parseInt(usize, header.value, 10);
                }
            }
        }
        etag = _x_etag orelse etag;
        if (size == null or commit_hash == null or etag == null) {
            return error.MetadataIsNull;
        }

        return .{ .size = size.?, .commit_hash = commit_hash.?, .etag = etag.?, .redirect_link = redirect_link };
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

pub const Cache = struct {
    path: fs.Dir,
    const Self = @This();

    pub fn init(path: ?[]const u8, allocator: std.mem.Allocator) !Self {
        switch (builtin.os.tag) {
            .linux => {
                var dir: std.fs.Dir = undefined;
                if (path) |_path| {
                    dir = try fs.openDirAbsolute(_path, .{ .iterate = true });
                } else {
                    const cache_dir_path = try utils.get_cache(allocator);
                    var cache_dir = try fs.openDirAbsolute(cache_dir_path, .{});
                    defer cache_dir.close();
                    const huggingface_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ cache_dir_path, "/huggingface/hub" });
                    cache_dir.makePath(huggingface_dir) catch {};
                    dir = try fs.openDirAbsolute(huggingface_dir, .{ .iterate = true });
                }

                return .{ .path = dir };
            },
            else => {
                @compileError("This lib doesn't support other than linux");
            },
        }
    }

    pub fn deinit(self: *Self) void {
        self.path.close();
    }

    pub fn blob_path(self: Self, repo: Repo, etag: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const repo_prefix = try self._repo_prefix(repo, allocator);
        const blobs_dir = try std.fmt.allocPrint(allocator, "{s}/blobs", .{repo_prefix});
        self.path.makePath(blobs_dir) catch {};
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ blobs_dir, etag });
    }

    pub fn pointer_path(self: Self, repo: Repo, commit_hash: []const u8, file_name: ?[]const u8, allocator: std.mem.Allocator) ![]const u8 {
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

    pub fn ref_path(self: Self, repo: Repo, allocator: std.mem.Allocator) ![]const u8 {
        const repo_prefix = try self._repo_prefix(repo, allocator);
        const ref_dir = try std.fmt.allocPrint(allocator, "{s}/refs", .{repo_prefix});
        self.path.makePath(ref_dir) catch {};
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_dir, repo.revision });
    }

    pub fn repo_path(self: Self, repo: Repo, allocator: std.mem.Allocator) !?RepoPath {
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
    try std.testing.expectStringEndsWith(path, "models--THUDM--codegeex4-all-9b/snapshots/6ee90cf42fbd24807825b5ff6bed9830a5a4cfb2/config.json");
}

test "RepoRedirectDownload" {
    var AA = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer AA.deinit();
    const allocator = AA.allocator();
    var repo = try Repo.init_with_repo_id("vidore/colpali", allocator);
    defer repo.deinit();
    const path = try repo.download("tokenizer.model", allocator);
    try std.testing.expectStringEndsWith(path, "hub/models--vidore--colpali/snapshots/1c18a0894f4e693c8e6689a08c6ad6eb018ef1fa/tokenizer.model");
    // _ = path;
}
