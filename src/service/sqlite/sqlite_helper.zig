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
                value.ptr,
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
