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
            .chunk_status = self.chunk_status,
        }, .{});
        return json;
    }

    fn deserialize(allocator: std.mem.Allocator, json: []const u8) !*UploadSession {
        const parsed = try std.json.parseFromSlice(struct {
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
            chunk_status: []bool,
        }, allocator, json, .{});
        defer parsed.deinit();

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
            .chunk_status = try allocator.dupe(bool, parsed.value.chunk_status),
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

            // Escape special characters in JSON
            var escaped_buf = try self.allocator.alloc(u8, json.len * 2);
            defer self.allocator.free(escaped_buf);
            var escaped_len: usize = 0;

            for (json) |character| {
                if (character == '"') {
                    escaped_buf[escaped_len] = '\\';
                    escaped_len += 1;
                }
                escaped_buf[escaped_len] = character;
                escaped_len += 1;
            }

            const escaped_json = escaped_buf[0..escaped_len];

            var cmd_buf: [4096]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "SET upload:{s} \"{s}\"", .{
                session.file_id,
                escaped_json,
            });

            const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd.ptr))));
            if (reply) |r| {
                defer c.freeReplyObject(r);
                if (r.type == c.REDIS_REPLY_ERROR) {
                    std.debug.print("Redis error: {s}\n", .{r.str[0..@intCast(r.len)]});
                    return RedisError.CommandFailed;
                }
            } else {
                std.debug.print("command failed", .{});
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

            const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd.ptr))));
            if (reply) |r| {
                defer c.freeReplyObject(r);
                if (r.type == c.REDIS_REPLY_STRING) {
                    const json = r.str[0..@intCast(r.len)];
                    return UploadSession.deserialize(self.allocator, json);
                } else {
                    return RedisError.SessionNotFound;
                }
            } else {
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