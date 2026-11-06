//! Shared by the command-line tools: edge-list loading and small file helpers.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

pub const InputEdge = extern struct { u: u64, v: u64, w: f32, _pad: u32 = 0 };

pub fn readFile(gpa: Allocator, path: []const u8) ![]u8 {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const fd = c.open(z, .{}, @as(c.mode_t, 0));
    if (fd < 0) return error.CannotOpen;
    defer _ = c.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.ensureTotalCapacity(gpa, 1 << 20);
    while (true) {
        try buf.ensureUnusedCapacity(gpa, 1 << 20);
        const space = buf.unusedCapacitySlice();
        const n = c.read(fd, space.ptr, space.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        buf.items.len += @intCast(n);
    }
    return buf.toOwnedSlice(gpa);
}

pub fn writeFile(gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const fd = c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.CannotCreate;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

pub fn mkdir(gpa: Allocator, path: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    _ = c.mkdir(z, 0o755); // EEXIST is fine; a real failure shows up on first use
}

/// Parse "u v [w]" lines. Weight defaults to 1.
pub fn loadEdges(gpa: Allocator, path: []const u8) ![]InputEdge {
    const bytes = try readFile(gpa, path);
    defer gpa.free(bytes);
    var out: std.ArrayList(InputEdge) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const a = f.next() orelse continue;
        const b = f.next() orelse return error.BadEdgeList;
        const u = try std.fmt.parseInt(u64, a, 10);
        const v = try std.fmt.parseInt(u64, b, 10);
        const w: f32 = if (f.next()) |t| try std.fmt.parseFloat(f32, t) else 1;
        try out.append(gpa, .{ .u = u, .v = v, .w = w });
    }
    return out.toOwnedSlice(gpa);
}

pub fn shuffle(edges: []InputEdge, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(InputEdge, edges);
}
