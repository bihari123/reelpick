const std = @import("std");
const zap = @import("zap");

const Thread = std.Thread;
const fileserver = @import("./file_server/file_server.zig");

const repo = @import("./file_server/db.zig");
const opensearch = @import("./file_server/service/opensearch/opensearch_helper.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try repo.initConnectionPool(allocator);

    defer repo.pool.deinit();

    try repo.db_init();

    // Initialize server
    var server = try fileserver.FileServer.init(allocator);
    defer server.deinit();

    // Start server
    const port: u16 = 5000;
    std.debug.print("Starting file server on port {d}...\n", .{port});
    try server.start(port);
}
