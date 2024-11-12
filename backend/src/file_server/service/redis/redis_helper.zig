const std = @import("std");
const c = @cImport({
    @cInclude("hiredis/hiredis.h");
});

pub const SessionStatus = enum {
    initializing,
    uploading,
    finalizing,
    completed,
    failed,
};

pub const RedisError = error{
    ConnectionFailed,
    CommandFailed,
    InvalidSessionData,
    SessionNotFound,
    UpdateFailed,
    SerializationFailed,
    DeserializationFailed,
};

pub const UploadSession = struct {
    file_id: []const u8,
    file_name: []const u8,
    total_size: usize,
    chunk_size: usize,
    total_chunks: usize,
    uploaded_chunks: usize,
    uploaded_size: usize,
    status: SessionStatus,
    created_at: i64,
    updated_at: i64,
    chunk_status: []bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file_id: []const u8, file_name: []const u8, total_size: usize, chunk_size: usize) !*UploadSession {
        const total_chunks = (total_size + chunk_size - 1) / chunk_size;
        const chunk_status = try allocator.alloc(bool, total_chunks);
        @memset(chunk_status, false);

        const session = try allocator.create(UploadSession);
        session.* = .{
            .file_id = try allocator.dupe(u8, file_id),
            .file_name = try allocator.dupe(u8, file_name),
            .total_size = total_size,
            .chunk_size = chunk_size,
            .total_chunks = total_chunks,
            .uploaded_chunks = 0,
            .uploaded_size = 0,
            .status = .initializing,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .chunk_status = chunk_status,
            .allocator = allocator,
        };
        return session;
    }

    pub fn deinit(self: *UploadSession) void {
        self.allocator.free(self.file_id);
        self.allocator.free(self.file_name);
        self.allocator.free(self.chunk_status);
        self.allocator.destroy(self);
    }

    fn serialize(self: *const UploadSession) ![]const u8 {
        // Create a temporary array for chunk status that's compatible with JSON
        var chunk_status_array = try std.ArrayList(u8).initCapacity(self.allocator, self.total_chunks);
        defer chunk_status_array.deinit();

        for (self.chunk_status) |status| {
            try chunk_status_array.append(if (status) 1 else 0);
        }

        const json = try std.json.stringifyAlloc(self.allocator, .{
            .file_id = self.file_id,
            .file_name = self.file_name,
            .total_size = self.total_size,
            .chunk_size = self.chunk_size,
            .total_chunks = self.total_chunks,
            .uploaded_chunks = self.uploaded_chunks,
            .uploaded_size = self.uploaded_size,
            .status = @tagName(self.status),
            .created_at = self.created_at,
            .updated_at = self.updated_at,
            .chunk_status = chunk_status_array.items,
        }, .{});

        // std.debug.print("Serialized JSON: {s}\n", .{json});
        return json;
    }

    fn deserialize(allocator: std.mem.Allocator, json: []const u8) !*UploadSession {
        // std.debug.print("Deserializing JSON: {s}\n", .{json});

        const ParsedData = struct {
            file_id: []const u8,
            file_name: []const u8,
            total_size: usize,
            chunk_size: usize,
            total_chunks: usize,
            uploaded_chunks: usize,
            uploaded_size: usize,
            status: []const u8,
            created_at: i64,
            updated_at: i64,
            chunk_status: []u8,
        };

        const parsed = try std.json.parseFromSlice(ParsedData, allocator, json, .{});
        defer parsed.deinit();

        var chunk_status = try allocator.alloc(bool, parsed.value.total_chunks);
        for (parsed.value.chunk_status, 0..) |status, i| {
            chunk_status[i] = status != 0;
        }

        const session = try allocator.create(UploadSession);
        session.* = .{
            .file_id = try allocator.dupe(u8, parsed.value.file_id),
            .file_name = try allocator.dupe(u8, parsed.value.file_name),
            .total_size = parsed.value.total_size,
            .chunk_size = parsed.value.chunk_size,
            .total_chunks = parsed.value.total_chunks,
            .uploaded_chunks = parsed.value.uploaded_chunks,
            .uploaded_size = parsed.value.uploaded_size,
            .status = std.meta.stringToEnum(SessionStatus, parsed.value.status) orelse .initializing,
            .created_at = parsed.value.created_at,
            .updated_at = parsed.value.updated_at,
            .chunk_status = chunk_status,
            .allocator = allocator,
        };

        return session;
    }
};

pub const RedisClient = struct {
    context: ?*c.redisContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !RedisClient {
        var host_buf: [256]u8 = undefined;
        const host_z = try std.fmt.bufPrintZ(&host_buf, "{s}", .{host});

        const ctx = c.redisConnect(host_z.ptr, port);
        if (ctx == null) {
            return RedisError.ConnectionFailed;
        }
        if (ctx.*.err != 0) {
            c.redisFree(ctx);
            return RedisError.ConnectionFailed;
        }

        return RedisClient{
            .context = ctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RedisClient) void {
        if (self.context) |ctx| {
            c.redisFree(ctx);
            self.context = null;
        }
    }

    pub fn setSession(self: *RedisClient, session: *UploadSession) !void {
        if (self.context) |ctx| {
            const json = try session.serialize();
            defer self.allocator.free(json);

            var cmd_buf: [4096]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "SET upload:{s} {s}", .{
                session.file_id,
                json,
            });

            // std.debug.print("Redis SET command: {s}\n", .{cmd});

            const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd.ptr))));
            if (reply) |r| {
                defer c.freeReplyObject(r);
                if (r.type == c.REDIS_REPLY_ERROR) {
                    std.debug.print("Redis error: {s}\n", .{r.str[0..@intCast(r.len)]});
                    return RedisError.CommandFailed;
                }
            } else {
                return RedisError.CommandFailed;
            }
        } else {
            return RedisError.ConnectionFailed;
        }
    }

    pub fn getSession(self: *RedisClient, file_id: []const u8) !*UploadSession {
        if (self.context) |ctx| {
            var cmd_buf: [256]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "GET upload:{s}", .{file_id});

            //    std.debug.print("Redis GET command: {s}\n", .{cmd});

            const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd.ptr))));
            if (reply) |r| {
                defer c.freeReplyObject(r);
                if (r.type == c.REDIS_REPLY_STRING) {
                    const json = r.str[0..@intCast(r.len)];
                    // std.debug.print("Retrieved JSON from Redis: {s}\n", .{json});
                    return UploadSession.deserialize(self.allocator, json);
                } else {
                    std.debug.print("Redis GET returned non-string response type: {d}\n", .{r.type});
                    return RedisError.SessionNotFound;
                }
            } else {
                std.debug.print("Redis GET command failed\n", .{});
                return RedisError.CommandFailed;
            }
        } else {
            return RedisError.ConnectionFailed;
        }
    }

    pub fn updateChunkStatus(self: *RedisClient, file_id: []const u8, chunk_index: usize, uploaded_size: usize) !void {
        var session = try self.getSession(file_id);
        defer session.deinit();

        session.chunk_status[chunk_index] = true;
        session.uploaded_chunks += 1;
        session.uploaded_size += uploaded_size;
        session.updated_at = std.time.timestamp();

        if (session.uploaded_chunks == session.total_chunks) {
            session.status = .finalizing;
        }

        try self.setSession(session);
    }

    pub fn deleteSession(self: *RedisClient, file_id: []const u8) !void {
        if (self.context) |ctx| {
            var cmd_buf: [256]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "DEL upload:{s}", .{file_id});

            const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd.ptr))));
            if (reply) |r| {
                defer c.freeReplyObject(r);
                if (r.type == c.REDIS_REPLY_ERROR) {
                    return RedisError.CommandFailed;
                }
            } else {
                return RedisError.CommandFailed;
            }
        } else {
            return RedisError.ConnectionFailed;
        }
    }
};

// Tests
const testing = std.testing;

test "UploadSession - initialization" {
    const allocator = testing.allocator;

    const file_id = "test123";
    const file_name = "test.txt";
    const total_size: usize = 1000;
    const chunk_size: usize = 100;

    var session = try UploadSession.init(allocator, file_id, file_name, total_size, chunk_size);
    defer session.deinit();

    try testing.expectEqualStrings(file_id, session.file_id);
    try testing.expectEqualStrings(file_name, session.file_name);
    try testing.expectEqual(total_size, session.total_size);
    try testing.expectEqual(chunk_size, session.chunk_size);
    try testing.expectEqual(@as(usize, 10), session.total_chunks);
    try testing.expectEqual(@as(usize, 0), session.uploaded_chunks);
    try testing.expectEqual(@as(usize, 0), session.uploaded_size);
    try testing.expectEqual(SessionStatus.initializing, session.status);

    // Verify chunk_status initialization
    for (session.chunk_status) |status| {
        try testing.expect(!status);
    }
}

test "UploadSession - serialization and deserialization" {
    const allocator = testing.allocator;

    // Create a test session
    var original = try UploadSession.init(allocator, "test123", "test.txt", 1000, 100);
    defer original.deinit();

    // Modify some values to test full serialization
    original.uploaded_chunks = 5;
    original.uploaded_size = 500;
    original.chunk_status[0] = true;
    original.chunk_status[1] = true;

    // Serialize
    const json = try original.serialize();
    defer allocator.free(json);

    // Deserialize
    var deserialized = try UploadSession.deserialize(allocator, json);
    defer deserialized.deinit();

    // Verify all fields match
    try testing.expectEqualStrings(original.file_id, deserialized.file_id);
    try testing.expectEqualStrings(original.file_name, deserialized.file_name);
    try testing.expectEqual(original.total_size, deserialized.total_size);
    try testing.expectEqual(original.chunk_size, deserialized.chunk_size);
    try testing.expectEqual(original.total_chunks, deserialized.total_chunks);
    try testing.expectEqual(original.uploaded_chunks, deserialized.uploaded_chunks);
    try testing.expectEqual(original.uploaded_size, deserialized.uploaded_size);
    try testing.expectEqual(original.status, deserialized.status);

    // Verify chunk status array
    for (original.chunk_status, 0..) |status, i| {
        try testing.expectEqual(status, deserialized.chunk_status[i]);
    }
}

test "UploadSession - json operations" {
    const allocator = testing.allocator;

    // Create session
    var original = try UploadSession.init(allocator, "test123", "test.txt", 1000, 100);
    defer original.deinit();

    // Test serialization
    const json = try original.serialize();
    defer allocator.free(json);

    // Test deserialization
    var deserialized = try UploadSession.deserialize(allocator, json);
    defer deserialized.deinit();

    try testing.expectEqualStrings(original.file_id, deserialized.file_id);
}
test "UploadSession - full cycle" {
    const allocator = testing.allocator;

    // Create original session
    var original = try UploadSession.init(allocator, "test123", "test.txt", 1000, 100);
    defer original.deinit();

    // Serialize it
    const json = try original.serialize();
    defer allocator.free(json);

    // Deserialize back
    var restored = try UploadSession.deserialize(allocator, json);
    defer restored.deinit();

    // Verify fields match
    try testing.expectEqualStrings(original.file_id, restored.file_id);
    try testing.expectEqualStrings(original.file_name, restored.file_name);
    try testing.expectEqual(original.total_size, restored.total_size);
    try testing.expectEqual(original.chunk_size, restored.chunk_size);
    try testing.expectEqual(original.total_chunks, restored.total_chunks);
}
