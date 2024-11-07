const sqlite = @import("../../../service/sqlite/sqlite_helper.zig");
const std = @import("std");
// Create connection pool
pub var pool: sqlite.ConnectionPool = undefined;

pub fn initConnectionPool(allocator: std.mem.Allocator) !void {
    pool = try sqlite.ConnectionPool.init(
        allocator,
        "test.db", // Use a file-based database instead of :memory: for thread safety
        10, // max connections
        300, // idle timeout in seconds
    );
}
pub fn db_init() !void {

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
}
pub fn update_chunk_table(file_id: []const u8, total_chunks: i64, uploaded_chunks: i64, chunk_path: []u8) void {
    var stmt = sqlite.ConnectionPool.PooledStatement.init(&pool,
        \\INSERT INTO video_chunk_data (file_id, total_chunks, chunks_received, chunk_locations, is_complete) 
        \\VALUES (?1,?2,?3,?4,?5)
    ) catch {
        std.log.err("Failed to initialize statement", .{});
        return; // Just return without the error
    };
    defer stmt.deinit();

    stmt.bindText(1, file_id) catch {
        std.log.err("Failed to bind text", .{});
        return;
    };

    stmt.bindInt(2, total_chunks) catch {
        std.log.err("Failed to bind int", .{});
        return;
    };

    stmt.bindInt(3, uploaded_chunks) catch {
        std.log.err("Failed to bind int", .{});
        return;
    };
    stmt.bindText(4, chunk_path) catch {
        std.log.err("Failed to bind text", .{});
        return;
    };
    stmt.bindInt(5, 1) catch {
        std.log.err("Failed to bind int", .{});
        return;
    };
    _ = stmt.step() catch {
        std.log.err("Failed to execute statement", .{});
        return;
    };
}

pub fn update_final_table(file_id: []const u8, file_size: i64, file_path: []u8) void {

    // var stmt = try sqlite.ConnectionPool.PooledStatement.init(&pool,
    //     \\INSERT INTO video_final_data (file_id, file_size, file_locations) VALUES (?1,?2,?3)
    // );
    // defer stmt.deinit();

    // try stmt.bindText(1, file_id);
    // try stmt.bindInt(2, file_size);
    // try stmt.bindText(3, file_path);
    // _ = try stmt.step();

    var stmt = sqlite.ConnectionPool.PooledStatement.init(&pool,
        \\INSERT INTO video_final_data (file_id, file_size, file_locations) VALUES (?1,?2,?3)
    ) catch {
        std.log.err("Failed to initialize statement", .{});
        return; // Just return without the error
    };
    defer stmt.deinit();

    stmt.bindText(1, file_id) catch {
        std.log.err("Failed to bind text", .{});
        return;
    };

    stmt.bindInt(2, file_size) catch {
        std.log.err("Failed to bind int", .{});
        return;
    };

    stmt.bindText(4, file_path) catch {
        std.log.err("Failed to bind text", .{});
        return;
    };

    _ = stmt.step() catch {
        std.log.err("Failed to execute statement", .{});
        return;
    };
}
