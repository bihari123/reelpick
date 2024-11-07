const std = @import("std");
const zap = @import("zap");
const redis = @import("./layer/service/redis/redis_helper.zig");
const sqlite = @import("./layer/service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const fileserver=@import("./server/file_server.zig");
 

// Create connection pool
var pool: sqlite.ConnectionPool = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    pool = try sqlite.ConnectionPool.init(
        allocator,
        "test.db", // Use a file-based database instead of :memory: for thread safety
        10, // max connections
        300, // idle timeout in seconds
    );

    defer pool.deinit();

    // Initialize general purpose allocator

    // Create table using initial connection
    {
        var stmt = try sqlite.ConnectionPool.PooledStatement.init(&pool,
            \\       CREATE TABLE IF NOT EXISTS video_chunk_data (
            \\  file_id TEXT PRIMARY KEY,
            \\  total_chunks INTEGER NOT NULL,
            \\    chunks_received INTEGER DEFAULT 0,
            \\  chunk_locations TEXT,  
            \\ created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\ updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\  is_complete BOOLEAN DEFAULT FALSE
            \\);       
        );
        defer stmt.deinit();
        _ = try stmt.step();
    }
    {
        var stmt = try sqlite.ConnectionPool.PooledStatement.init(&pool,
            \\       CREATE TABLE IF NOT EXISTS video_final_data (
            \\  file_id TEXT PRIMARY KEY,
            \\  file_size INTEGER NOT NULL,
            \\  file_locations TEXT,  
            \\ created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\);       
        );
        defer stmt.deinit();
        _ = try stmt.step();
    }

    // Initialize server
    var server = try fileserver.FileServer.init(allocator);
    defer server.deinit();

    // Start server
    const port: u16 = 5000;
    std.debug.print("Starting file server on port {d}...\n", .{port});
    try server.start(port);
}
