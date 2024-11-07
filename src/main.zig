const std = @import("std");
const sqlite = @import("./layer/service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;

// Example usage with multiple threads
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create connection pool
    var pool = try sqlite.ConnectionPool.init(
        allocator,
        "test.db", // Use a file-based database instead of :memory: for thread safety
        10, // max connections
        300, // idle timeout in seconds
    );
    defer pool.deinit();

    // Create table using initial connection
    {
        var stmt = try sqlite.ConnectionPool.PooledStatement.init(&pool,
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL
            \\)
        );
        defer stmt.deinit();
        _ = try stmt.step();
    }

    // Create and launch threads
    var threads: [4]Thread = undefined;

    for (0..4) |i| {
        const context = sqlite.ThreadContext{
            .pool = &pool,
            .id = i,
            .allocator = allocator,
        };
        threads[i] = try Thread.spawn(.{}, sqlite.workerThread, .{context});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }
}
