//! Thin wrappers over libc. Phase 1 talks to the OS directly (open, write,
//! fsync, flock, pthread) instead of std.fs / std.Io, so the engine does not
//! depend on the parts of std that change between Zig releases.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Error = error{ Io, Locked };

const is_mac = builtin.os.tag.isDarwin();

// open(2) flag values differ by OS; the common ones are spelled out here.
const O_RDONLY: u32 = 0;
const O_WRONLY: u32 = 1;
const O_RDWR: u32 = 2;
const O_CREAT: u32 = if (is_mac) 0x200 else 0x40;
const O_APPEND: u32 = if (is_mac) 0x8 else 0x400;
const O_CLOEXEC: u32 = if (is_mac) 0x1000000 else 0x80000;
const O_DIRECTORY: u32 = if (is_mac) 0x100000 else 0x10000;
const F_FULLFSYNC: c_int = 51; // macOS only
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;

pub const Mode = enum { read, read_write_create, append };

fn sysOpen(path: [*:0]const u8, flags: u32) c_int {
    while (true) {
        const rc = c.open(path, @as(c.O, @bitCast(flags)), @as(c.mode_t, 0o644));
        if (rc >= 0) return rc;
        if (c.errno(rc) == .INTR) continue;
        return rc;
    }
}

pub const File = struct {
    fd: c_int,

    pub fn open(path: [*:0]const u8, mode: Mode) error{Io}!File {
        return (try openOptional(path, mode)) orelse error.Io;
    }

    /// Like `open`, but a missing file is `null` rather than an error.
    pub fn openOptional(path: [*:0]const u8, mode: Mode) error{Io}!?File {
        const flags: u32 = O_CLOEXEC | switch (mode) {
            .read => O_RDONLY,
            .read_write_create => O_RDWR | O_CREAT,
            .append => O_WRONLY | O_APPEND,
        };
        const fd = sysOpen(path, flags);
        if (fd < 0) return if (c.errno(fd) == .NOENT) null else error.Io;
        return .{ .fd = fd };
    }

    pub fn close(f: File) void {
        _ = c.close(f.fd);
    }

    pub fn writeAll(f: File, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = c.write(f.fd, bytes.ptr + off, bytes.len - off);
            if (rc < 0) {
                if (c.errno(rc) == .INTR) continue;
                return error.Io;
            }
            if (rc == 0) return error.Io;
            off += @intCast(rc);
        }
    }

    /// Flush file data to stable storage. Plain fsync(2) on macOS only reaches
    /// the drive's cache; F_FULLFSYNC asks the drive to flush it.
    pub fn sync(f: File) Error!void {
        if (is_mac) {
            if (c.fcntl(f.fd, F_FULLFSYNC) == 0) return;
            // Some filesystems reject F_FULLFSYNC; fall back to fsync.
        }
        while (true) {
            const rc = c.fsync(f.fd);
            if (rc == 0) return;
            if (c.errno(rc) == .INTR) continue;
            return error.Io;
        }
    }

    pub fn truncate(f: File, len: u64) Error!void {
        if (c.ftruncate(f.fd, @intCast(len)) != 0) return error.Io;
    }

    pub fn size(f: File) Error!u64 {
        const end = c.lseek(f.fd, 0, c.SEEK.END);
        if (end < 0) return error.Io;
        _ = c.lseek(f.fd, 0, c.SEEK.SET);
        return @intCast(end);
    }

    /// Read the whole file. Caller frees with `gpa`.
    pub fn readAll(f: File, gpa: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]u8 {
        const n: usize = @intCast(try f.size());
        const buf = try gpa.alloc(u8, n);
        errdefer gpa.free(buf);
        var off: usize = 0;
        while (off < n) {
            const rc = c.pread(f.fd, buf.ptr + off, n - off, @intCast(off));
            if (rc < 0) {
                if (c.errno(rc) == .INTR) continue;
                return error.Io;
            }
            if (rc == 0) return error.Io; // file shrank under us
            off += @intCast(rc);
        }
        return buf;
    }

    /// Non-blocking exclusive lock; the lock dies with the process.
    pub fn lockExclusive(f: File) Error!void {
        const rc = c.flock(f.fd, LOCK_EX | LOCK_NB);
        if (rc == 0) return;
        return if (c.errno(rc) == .AGAIN) error.Locked else error.Io;
    }
};

/// fsync a directory so that creates, renames and unlinks inside it are durable.
pub fn syncDir(path: [*:0]const u8) Error!void {
    const fd = sysOpen(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return error.Io;
    const f: File = .{ .fd = fd };
    defer f.close();
    try f.sync();
}

/// Create a directory; succeeds if it already exists.
pub fn makeDir(path: [*:0]const u8) Error!void {
    const rc = c.mkdir(path, 0o755);
    if (rc == 0 or c.errno(rc) == .EXIST) return;
    return error.Io;
}

pub fn unlink(path: [*:0]const u8) void {
    _ = c.unlink(path);
}

pub fn rmdir(path: [*:0]const u8) void {
    _ = c.rmdir(path);
}

pub const Mutex = struct {
    m: c.pthread_mutex_t = .{},

    pub fn lock(mu: *Mutex) void {
        _ = c.pthread_mutex_lock(&mu.m);
    }
    pub fn unlock(mu: *Mutex) void {
        _ = c.pthread_mutex_unlock(&mu.m);
    }
};

pub const RwLock = struct {
    l: c.pthread_rwlock_t = .{},

    pub fn lockShared(rw: *RwLock) void {
        _ = c.pthread_rwlock_rdlock(&rw.l);
    }
    pub fn lock(rw: *RwLock) void {
        _ = c.pthread_rwlock_wrlock(&rw.l);
    }
    pub fn unlock(rw: *RwLock) void {
        _ = c.pthread_rwlock_unlock(&rw.l);
    }
};

pub fn rename(from: [*:0]const u8, to: [*:0]const u8) Error!void {
    if (c.rename(from, to) != 0) return error.Io;
}

// Declared here instead of using std.c's versions: the flag types for
// PROT/MAP differ per OS and per Zig release, the numeric values below do not.
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
const PROT_READ: c_int = 1;
const MAP_PRIVATE: c_int = 2;

pub const page_align = std.heap.page_size_min;
pub const Mapping = []align(page_align) const u8;

/// Map a whole file read-only. `len` must be > 0 and <= the file size.
pub fn mapFile(f: File, len: usize) Error!Mapping {
    const p = mmap(null, len, PROT_READ, MAP_PRIVATE, f.fd, 0) orelse return error.Io;
    if (@intFromPtr(p) == std.math.maxInt(usize)) return error.Io; // MAP_FAILED
    const ptr: [*]align(page_align) const u8 = @ptrCast(@alignCast(p));
    return ptr[0..len];
}

pub fn unmap(m: Mapping) void {
    _ = munmap(@ptrCast(@constCast(m.ptr)), m.len);
}

/// Names (not paths) of the entries of `dir`, excluding "." and "..".
/// Caller frees each name and the list.
pub fn listDir(gpa: std.mem.Allocator, dir: [*:0]const u8) (Error || std.mem.Allocator.Error)![][]u8 {
    const d = c.opendir(dir) orelse return error.Io;
    defer _ = c.closedir(d);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try names.append(gpa, copy);
    }
    return names.toOwnedSlice(gpa);
}
