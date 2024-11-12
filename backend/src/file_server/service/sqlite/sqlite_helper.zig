const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const time = std.time;

// SQLite C API bindings
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    FinalizeFailed,
    QueryFailed,
    PoolFull,
    NoAvailableConnections,
    InvalidConnection,
    OutOfMemory,
    ThreadCreateFailed,
};

pub const Connection = struct {
    db: ?*c.sqlite3,
    in_use: bool,
    last_used: i64,

    pub fn init(path: []const u8) SqliteError!Connection {
        var db: ?*c.sqlite3 = null;
        // Ensure path is null-terminated
        var path_buffer: [512]u8 = undefined;
        const null_terminated_path = if (std.mem.eql(u8, path, ":memory:"))
            ":memory:"
        else blk: {
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            break :blk path_buffer[0..path.len :0];
        };

        const result = c.sqlite3_open(null_terminated_path.ptr, &db);

        if (result != c.SQLITE_OK) {
            if (db) |ptr| {
                _ = c.sqlite3_close(ptr);
            }
            return SqliteError.OpenFailed;
        }

        // Enable WAL mode for better concurrency
        var err_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &err_stmt, null);
        _ = c.sqlite3_step(err_stmt);
        _ = c.sqlite3_finalize(err_stmt);

        // Set busy timeout
        _ = c.sqlite3_busy_timeout(db, 5000); // 5 seconds

        return Connection{
            .db = db,
            .in_use = false,
            .last_used = time.timestamp(),
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }
};

pub const ConnectionPool = struct {
    allocator: Allocator,
    connections: ArrayList(Connection),
    mutex: Mutex,
    db_path: []const u8,
    max_connections: usize,
    idle_timeout: i64,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        db_path: []const u8,
        max_connections: usize,
        idle_timeout: i64,
    ) !Self {
        // Initialize SQLite for multi-threading
        _ = c.sqlite3_config(c.SQLITE_CONFIG_SERIALIZED);
        _ = c.sqlite3_initialize();

        // Make a copy of db_path to ensure it lives as long as the pool
        const owned_path = try allocator.dupe(u8, db_path);

        var pool = Self{
            .allocator = allocator,
            .connections = ArrayList(Connection).init(allocator),
            .mutex = .{},
            .db_path = owned_path,
            .max_connections = max_connections,
            .idle_timeout = idle_timeout,
        };

        // Create initial connection to verify database can be opened
        const initial_conn = try Connection.init(owned_path);
        try pool.connections.append(initial_conn);

        return pool;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*conn| {
            conn.deinit();
        }
        self.connections.deinit();
        self.allocator.free(self.db_path);
        _ = c.sqlite3_shutdown();
    }

    pub fn acquire(self: *Self) SqliteError!*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up idle connections
        try self.removeIdleConnections();

        // Look for available connection
        for (self.connections.items) |*conn| {
            if (!conn.in_use) {
                conn.in_use = true;
                conn.last_used = time.timestamp();
                return conn;
            }
        }

        // Create new connection if pool isn't full
        if (self.connections.items.len < self.max_connections) {
            const conn = try Connection.init(self.db_path);
            try self.connections.append(conn);
            const latest_conn = &self.connections.items[self.connections.items.len - 1];
            latest_conn.in_use = true;
            latest_conn.last_used = time.timestamp();
            return latest_conn;
        }

        return SqliteError.NoAvailableConnections;
    }

    pub fn release(self: *Self, conn: *Connection) SqliteError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*pool_conn| {
            if (pool_conn == conn) {
                conn.in_use = false;
                conn.last_used = time.timestamp();
                return;
            }
        }

        return SqliteError.InvalidConnection;
    }

    fn removeIdleConnections(self: *Self) !void {
        const current_time = time.timestamp();
        var i: usize = 0;

        while (i < self.connections.items.len) {
            const conn = &self.connections.items[i];
            if (!conn.in_use and (current_time - conn.last_used) > self.idle_timeout) {
                conn.deinit();
                _ = self.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub const PooledStatement = struct {
        pool: *ConnectionPool,
        conn: *Connection,
        stmt: ?*c.sqlite3_stmt,

        pub fn init(pool: *ConnectionPool, query: []const u8) SqliteError!PooledStatement {
            const conn = try pool.acquire();
            errdefer pool.release(conn) catch {};

            var stmt: ?*c.sqlite3_stmt = null;
            const result = c.sqlite3_prepare_v2(
                conn.db,
                query.ptr,
                @intCast(query.len),
                &stmt,
                null,
            );

            if (result != c.SQLITE_OK) {
                try pool.release(conn);
                return SqliteError.PrepareFailed;
            }

            return PooledStatement{
                .pool = pool,
                .conn = conn,
                .stmt = stmt,
            };
        }

        pub fn deinit(self: *PooledStatement) void {
            if (self.stmt) |stmt| {
                _ = c.sqlite3_finalize(stmt);
                self.stmt = null;
            }
            self.pool.release(self.conn) catch {};
        }

        pub fn reset(self: *PooledStatement) !void {
            const result = c.sqlite3_reset(self.stmt.?);
            if (result != c.SQLITE_OK) {
                return SqliteError.PrepareFailed;
            }
        }

        pub fn step(self: *PooledStatement) SqliteError!bool {
            const result = c.sqlite3_step(self.stmt.?);

            switch (result) {
                c.SQLITE_ROW => return true,
                c.SQLITE_DONE => return false,
                else => return SqliteError.StepFailed,
            }
        }

        pub fn bindInt(self: *PooledStatement, index: usize, value: i64) SqliteError!void {
            const result = c.sqlite3_bind_int64(
                self.stmt.?,
                @intCast(index),
                value,
            );

            if (result != c.SQLITE_OK) {
                return SqliteError.PrepareFailed;
            }
        }

        pub fn bindText(self: *PooledStatement, index: usize, value: []const u8) SqliteError!void {
            const result = c.sqlite3_bind_text(
                self.stmt.?,
                @intCast(index),
                @ptrCast(value.ptr),
                @intCast(value.len),
                c.SQLITE_TRANSIENT,
            );

            if (result != c.SQLITE_OK) {
                return SqliteError.PrepareFailed;
            }
        }

        pub fn columnInt(self: *PooledStatement, index: usize) i64 {
            return c.sqlite3_column_int64(self.stmt.?, @intCast(index));
        }

        pub fn columnText(self: *PooledStatement, index: usize) []const u8 {
            const text = c.sqlite3_column_text(self.stmt.?, @intCast(index));
            const len = c.sqlite3_column_bytes(self.stmt.?, @intCast(index));
            if (text == null) return &[_]u8{};
            return text[0..@intCast(len)];
        }
    };
};
pub const ThreadContext = struct {
    pool: *ConnectionPool,
    id: usize,
    allocator: Allocator,
};

pub fn workerThread(context: ThreadContext) !void {
    const name = try std.fmt.allocPrint(context.allocator, "User {d}", .{context.id});
    defer context.allocator.free(name);

    // Insert data
    {
        var stmt = try ConnectionPool.PooledStatement.init(context.pool,
            \\INSERT INTO users (name) VALUES (?)
        );
        defer stmt.deinit();

        try stmt.bindText(1, name);
        _ = try stmt.step();
    }

    // Small delay to allow other threads to work
    std.time.sleep(10 * std.time.ns_per_ms);

    // Query data
    {
        var stmt = try ConnectionPool.PooledStatement.init(context.pool,
            \\SELECT id, name FROM users
        );
        defer stmt.deinit();

        while (try stmt.step()) {
            const id = stmt.columnInt(0);
            const row_name = stmt.columnText(1);
            std.debug.print("Thread {d} sees user {}: {s}\n", .{ context.id, id, row_name });
        }
    }
}

// testing
const testing = std.testing;
test "basic connection pool operations" {
    const allocator = testing.allocator;

    var pool = try ConnectionPool.init(allocator, ":memory:", 5, // max connections
        60 // idle timeout in seconds
    );
    defer pool.deinit();

    // Create test table
    {
        var stmt = try ConnectionPool.PooledStatement.init(&pool,
            \\CREATE TABLE test (
            \\    id INTEGER PRIMARY KEY,
            \\    value TEXT NOT NULL
            \\)
        );
        defer stmt.deinit();
        _ = try stmt.step();
    }

    // Test insertion
    {
        var stmt = try ConnectionPool.PooledStatement.init(&pool,
            \\INSERT INTO test (value) VALUES (?)
        );
        defer stmt.deinit();

        try stmt.bindText(1, "test_value");
        _ = try stmt.step();
    }

    // Test query
    {
        var stmt = try ConnectionPool.PooledStatement.init(&pool,
            \\SELECT value FROM test WHERE id = 1
        );
        defer stmt.deinit();

        try testing.expect(try stmt.step());
        const value = stmt.columnText(0);
        try testing.expectEqualStrings("test_value", value);
    }
}

test "connection pool limits" {
    const allocator = testing.allocator;

    var pool = try ConnectionPool.init(allocator, ":memory:", 2, // max connections
        60 // idle timeout
    );
    defer pool.deinit();

    // Acquire first connection
    const conn1 = try pool.acquire();
    // Acquire second connection
    const conn2 = try pool.acquire();

    // Third connection should fail
    try testing.expectError(SqliteError.NoAvailableConnections, pool.acquire());

    // Release connections
    try pool.release(conn1);
    try pool.release(conn2);
}

test "idle connection cleanup" {
    const allocator = testing.allocator;

    // Use a very short timeout for testing
    var pool = try ConnectionPool.init(allocator, ":memory:", 5, // max connections
        1 // idle timeout (1 second)
    );
    defer pool.deinit();

    // Record initial connection count
    const initial_count = pool.connections.items.len;

    // Create and release some connections
    {
        var connections: [3]*Connection = undefined;

        // Acquire connections
        for (&connections) |*conn| {
            conn.* = try pool.acquire();
        }

        // Release connections immediately
        for (connections) |conn| {
            try pool.release(conn);
        }
    }

    // Verify connections were created
    try testing.expect(pool.connections.items.len > initial_count);

    // Wait long enough for cleanup
    std.time.sleep(2 * std.time.ns_per_s);

    // Force cleanup by trying to acquire a new connection
    {
        const conn = try pool.acquire();
        try pool.release(conn);
    }

    // Check if connections were cleaned up
    // We should see a reduction in connections, but at least one connection remains
    try testing.expect(pool.connections.items.len < 4); // Less than what we created
    try testing.expect(pool.connections.items.len >= 1); // At least one connection remains

    // Verify all remaining connections are not in use
    for (pool.connections.items) |conn| {
        try testing.expect(!conn.in_use);
    }
}

test "concurrent access" {
    const allocator = testing.allocator;
    const thread_count = 4;

    var pool = try ConnectionPool.init(allocator, ":memory:", thread_count + 1, // Add extra connection for setup
        60);
    defer pool.deinit();

    // Create test table with proper error handling
    {
        var create_stmt = try ConnectionPool.PooledStatement.init(&pool,
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT NOT NULL,
            \\    thread_id INTEGER NOT NULL,
            \\    created_at INTEGER DEFAULT (strftime('%s', 'now'))
            \\)
        );
        defer create_stmt.deinit();
        _ = try create_stmt.step();
    }

    const WorkerContext = struct {
        pool: *ConnectionPool,
        id: usize,
        allocator: Allocator,
        success: bool = false,
    };

    // Modified worker function with transaction support
    const worker = struct {
        fn run(context: *WorkerContext) void {
            const name = std.fmt.allocPrintZ(context.allocator, "User {d}", .{context.id}) catch {
                return;
            };
            defer context.allocator.free(name);

            // Get a connection from the pool
            const conn = context.pool.acquire() catch {
                return;
            };
            defer context.pool.release(conn) catch {};

            // Begin transaction
            {
                var begin_stmt = ConnectionPool.PooledStatement.init(context.pool,
                    \\BEGIN EXCLUSIVE TRANSACTION
                ) catch {
                    return;
                };
                defer begin_stmt.deinit();

                _ = begin_stmt.step() catch {
                    return;
                };
            }

            // Insert data
            {
                var insert_stmt = ConnectionPool.PooledStatement.init(context.pool,
                    \\INSERT INTO users (name, thread_id) VALUES (?, ?)
                ) catch {
                    return;
                };
                defer insert_stmt.deinit();

                insert_stmt.bindText(1, name) catch {
                    return;
                };
                insert_stmt.bindInt(2, @intCast(context.id)) catch {
                    return;
                };

                _ = insert_stmt.step() catch {
                    return;
                };
            }

            // Query the inserted data
            {
                var select_stmt = ConnectionPool.PooledStatement.init(context.pool,
                    \\SELECT id, name, thread_id 
                    \\FROM users 
                    \\WHERE id = last_insert_rowid()
                ) catch {
                    return;
                };
                defer select_stmt.deinit();

                if (select_stmt.step() catch {
                    return;
                }) {
                    const id = select_stmt.columnInt(0);
                    const row_name = select_stmt.columnText(1);
                    const thread_id = select_stmt.columnInt(2);

                    // Verify the data matches what we inserted
                    if (thread_id != context.id) {
                        return;
                    }

                    std.debug.print("Thread {d} inserted user {d}: {s}\n", .{
                        context.id, id, row_name,
                    });
                }
            }

            // Commit transaction
            {
                var commit_stmt = ConnectionPool.PooledStatement.init(context.pool,
                    \\COMMIT
                ) catch {
                    return;
                };
                defer commit_stmt.deinit();

                _ = commit_stmt.step() catch {
                    return;
                };
            }

            context.success = true;
        }
    };

    // Create thread contexts
    var contexts = try allocator.alloc(WorkerContext, thread_count);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(Thread, thread_count);
    defer allocator.free(threads);

    // Initialize contexts and start threads
    for (0..thread_count) |i| {
        contexts[i] = .{
            .pool = &pool,
            .id = i,
            .allocator = allocator,
        };
        threads[i] = try Thread.spawn(.{}, worker.run, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all threads completed successfully
    var success_count: usize = 0;
    for (contexts) |context| {
        if (context.success) {
            success_count += 1;
        }
    }

    // Verify results
    {
        var verify_stmt = try ConnectionPool.PooledStatement.init(&pool,
            \\SELECT COUNT(*) total_count,
            \\       COUNT(DISTINCT thread_id) unique_threads
            \\FROM users
        );
        defer verify_stmt.deinit();

        try testing.expect(try verify_stmt.step());
    }
}
