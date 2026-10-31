//! Spectrolith public API. Everything not re-exported here is private.
const db_mod = @import("db.zig");
const types = @import("types.zig");
const batch_mod = @import("batch.zig");

pub const Error = types.Error;
pub const Edge = types.Edge;
pub const SyncMode = db_mod.SyncMode;
pub const Options = db_mod.Options;
pub const Db = db_mod.Db;
pub const Snapshot = db_mod.Snapshot;
pub const EdgeIter = db_mod.EdgeIter;
pub const Batch = batch_mod.Batch;

test {
    _ = @import("sys.zig");
    _ = @import("wal.zig");
    _ = @import("memgraph.zig");
    _ = @import("db_test.zig");
}
