const std = @import("std");
const zap = @import("zap");
const redis = @import("./layer/service/redis/redis_helper.zig");
const sqlite = @import("./layer/service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const val = @import("./server_const.zig");

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    redis_client: redis.RedisClient,
    ep_initialize: zap.Endpoint,
    ep_chunk: zap.Endpoint,
    ep_status: zap.Endpoint,

    pub fn init(allocator: std.mem.Allocator) !*FileServer {
        // Create uploads directory
        try std.fs.cwd().makePath(val.UPLOAD_DIR);

        // Initialize Redis client
        const redis_client = try redis.RedisClient.init(allocator, "localhost", 6379);

        // Create server instance
        const server = try allocator.create(FileServer);
        errdefer allocator.destroy(server);

        server.* = .{
            .allocator = allocator,
            .redis_client = redis_client,
            .ep_initialize = zap.Endpoint.init(.{
                .path = "/api/upload/initialize",
                .post = handleInitialize,
                .options = handleOptions,
            }),
            .ep_chunk = zap.Endpoint.init(.{
                .path = "/api/upload/chunk",
                .post = handleChunk,
                .options = handleOptions,
            }),
            .ep_status = zap.Endpoint.init(.{
                .path = "/api/upload/status",
                .get = handleStatus,
                .options = handleOptions,
            }),
        };

        return server;
    }

    pub fn deinit(self: *FileServer) void {
        self.redis_client.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *FileServer, port: u16) !void {
        var listener = zap.Endpoint.Listener.init(self.allocator, .{
            .port = port,
            .on_request = null,
            .log = true,
            .max_body_size = val.MAX_FILE_SIZE,
        });
        defer listener.deinit();

        // Register endpoints
        try listener.register(&self.ep_initialize);
        try listener.register(&self.ep_chunk);
        try listener.register(&self.ep_status);

        try listener.listen();

        std.debug.print("Server listening on port {d}\n", .{port});

        // Start the event loop
        zap.start(.{
            .threads = 4,
            .workers = 1,
        });
    }

    fn handleInitialize(ep: *zap.Endpoint, r: zap.Request) void {
        const self: *FileServer = @fieldParentPtr("ep_initialize", ep);
        addCorsHeaders(r) catch return;

        validateAuth(r) catch |err| {
            if (err == val.UploadError.Unauthorized) {
                sendErrorJson(r, val.UploadError.Unauthorized, 401);
                return;
            }
            r.sendError(err, null, 500);
            return;
        };

        if (r.body) |body| {
            const parsed = std.json.parseFromSlice(struct {
                fileName: []const u8,
                fileSize: usize,
                totalChunks: usize,
            }, self.allocator, body, .{}) catch {
                sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
                return;
            };
            defer parsed.deinit();

            const init_data = parsed.value;

            if (init_data.fileSize > val.MAX_FILE_SIZE) {
                sendErrorJson(r, val.UploadError.FileTooLarge, 400);
                return;
            }

            // Generate file ID
            var random_bytes: [16]u8 = undefined;
            std.crypto.random.bytes(&random_bytes);
            var file_id_buf: [32]u8 = undefined;
            _ = std.fmt.bufPrint(&file_id_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch {
                sendErrorJson(r, val.UploadError.FileIdGenerationFailed, 500);
                return;
            };
            const file_id = file_id_buf[0..];

            // Create upload session
            const session = redis.UploadSession.init(
                self.allocator,
                file_id,
                init_data.fileName,
                init_data.fileSize,
                val.CHUNK_SIZE,
            ) catch {
                sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
                return;
            };
            defer session.deinit();

            // Store session in Redis
            self.redis_client.setSession(session) catch {
                sendErrorJson(r, val.UploadError.StoreSessionFailed, 500);
                return;
            };

            // Create chunk directory
            const chunk_dir = std.fs.path.join(
                self.allocator,
                &[_][]const u8{ val.UPLOAD_DIR, file_id },
            ) catch {
                sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
                return;
            };
            defer self.allocator.free(chunk_dir);

            std.fs.cwd().makePath(chunk_dir) catch {
                sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
                return;
            };

            // Send response
            const response = .{
                .fileId = file_id,
                .fileName = init_data.fileName,
                .fileSize = init_data.fileSize,
                .totalChunks = session.total_chunks,
                .chunkSize = val.CHUNK_SIZE,
            };

            var json_buf: [1024]u8 = undefined;
            const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
                r.sendError(val.UploadError.InvalidRequestBody, null, 500);
                return;
            };
            r.sendBody(json) catch return;
        }
    }

    fn handleChunk(ep: *zap.Endpoint, r: zap.Request) void {
        const self: *FileServer = @fieldParentPtr("ep_chunk", ep);
        addCorsHeaders(r) catch return;

        validateAuth(r) catch |err| {
            if (err == val.UploadError.Unauthorized) {
                std.debug.print("Invalid token", .{});
                sendErrorJson(r, val.UploadError.Unauthorized, 401);
                return;
            }
            r.sendError(err, null, 500);
            return;
        };

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, val.UploadError.MissingFileId, 400);
            return;
        };

        const chunk_index_str = r.getHeader("x-chunk-index") orelse {
            sendErrorJson(r, val.UploadError.MissingChunkIndex, 400);
            return;
        };

        const chunk_index = std.fmt.parseInt(usize, chunk_index_str, 10) catch {
            sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
            return;
        };

        const chunk_data = r.body orelse {
            sendErrorJson(r, val.UploadError.MissingChunkData, 400);
            return;
        };

        // Get session from Redis
        const session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, val.UploadError.InvalidSession, 400);
            return;
        };
        defer session.deinit();

        // Validate chunk size and index
        if (chunk_index >= session.total_chunks) {
            sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
            return;
        }

        // Write chunk to file
        const chunk_dir = std.fs.path.join(
            self.allocator,
            &[_][]const u8{ val.UPLOAD_DIR, file_id },
        ) catch {
            sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
            return;
        };
        defer self.allocator.free(chunk_dir);

        const chunk_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/chunk_{d}",
            .{ chunk_dir, chunk_index },
        ) catch {
            sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
            return;
        };
        defer self.allocator.free(chunk_path);

        const chunk_file = std.fs.cwd().createFile(chunk_path, .{}) catch {
            sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
            return;
        };
        defer chunk_file.close();

        chunk_file.writeAll(chunk_data) catch {
            sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
            return;
        };

        // Update session in Redis
        self.redis_client.updateChunkStatus(file_id, chunk_index, chunk_data.len) catch {
            sendErrorJson(r, val.UploadError.RedisError, 500);
            return;
        };

        // Get updated session for response
        const updated_session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, val.UploadError.RedisError, 500);
            return;
        };
        defer updated_session.deinit();

        // Check if all chunks are uploaded and finalize if needed
        if (updated_session.uploaded_chunks == updated_session.total_chunks) {
            finalizeUpload(self, updated_session) catch |err| {
                sendErrorJson(r, err, 500);
                return;
            };
        }

        // Calculate progress
        const progress = @as(f32, @floatFromInt(updated_session.uploaded_size)) /
            @as(f32, @floatFromInt(updated_session.total_size)) * 100.0;

        // Send response
        const response = .{
            .received = true,
            .status = @tagName(updated_session.status),
            .progress = @as(u8, @intFromFloat(progress)),
            .uploadedSize = updated_session.uploaded_size,
            .totalSize = updated_session.total_size,
            .message = "chunk upload successful",
        };

        var json_buf: [1024]u8 = undefined;
        const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
            r.sendError(val.UploadError.InvalidRequestBody, null, 500);
            return;
        };
        r.sendBody(json) catch return;
        {
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
            const total_chunks = std.math.cast(i64, updated_session.total_chunks) orelse 0;

            stmt.bindInt(2, total_chunks) catch {
                std.log.err("Failed to bind int", .{});
                return;
            };
            const uploaded_chunks = std.math.cast(i64, updated_session.uploaded_chunks) orelse 0;
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
    }

    fn handleStatus(ep: *zap.Endpoint, r: zap.Request) void {
        const self: *FileServer = @fieldParentPtr("ep_status", ep);
        addCorsHeaders(r) catch return;

        validateAuth(r) catch |err| {
            if (err == val.UploadError.Unauthorized) {
                sendErrorJson(r, val.UploadError.Unauthorized, 401);
                return;
            }
            r.sendError(err, null, 500);
            return;
        };

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, val.UploadError.MissingFileId, 400);
            return;
        };

        const session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, val.UploadError.InvalidSession, 400);
            return;
        };
        defer session.deinit();

        const progress = @as(f32, @floatFromInt(session.uploaded_size)) /
            @as(f32, @floatFromInt(session.total_size)) * 100.0;

        const response = .{
            .status = @tagName(session.status),
            .progress = @as(u8, @intFromFloat(progress)),
            .uploadedSize = session.uploaded_size,
            .totalSize = session.total_size,
            .totalChunks = session.total_chunks,
            .uploadedChunks = session.uploaded_chunks,
        };

        var json_buf: [1024]u8 = undefined;
        const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
            r.sendError(val.UploadError.InvalidRequestBody, null, 500);
            return;
        };
        r.sendBody(json) catch return;
    }

    fn handleOptions(ep: *zap.Endpoint, r: zap.Request) void {
        _ = ep;
        addCorsHeaders(r) catch return;
        r.setStatus(.no_content);
    }

    fn finalizeUpload(self: *FileServer, session: *redis.UploadSession) !void {
        const chunk_dir = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ val.UPLOAD_DIR, session.file_id },
        );
        defer self.allocator.free(chunk_dir);

        const final_path = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ val.UPLOAD_DIR, session.file_name },
        );
        defer self.allocator.free(final_path);

        const final_file = try std.fs.cwd().createFile(final_path, .{});
        defer final_file.close();

        // Combine all chunks
        var i: usize = 0;
        while (i < session.total_chunks) : (i += 1) {
            const chunk_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/chunk_{d}",
                .{ chunk_dir, i },
            );
            defer self.allocator.free(chunk_path);

            const chunk_data = try std.fs.cwd().readFileAlloc(
                self.allocator,
                chunk_path,
                val.MAX_FILE_SIZE,
            );
            defer self.allocator.free(chunk_data);

            try final_file.writeAll(chunk_data);
            try std.fs.cwd().deleteFile(chunk_path);
        }

        {
            var stmt = try sqlite.ConnectionPool.PooledStatement.init(&pool,
                \\INSERT INTO video_final_data (file_id, file_size, file_locations) VALUES (?1,?2,?3)
            );
            defer stmt.deinit();

            try stmt.bindText(1, session.file_id);
            const file_size = std.math.cast(i64, final_file.getEndPos() catch 0) orelse 0;
            try stmt.bindInt(2, file_size);
            try stmt.bindText(3, final_path);
            _ = try stmt.step();
        }

        // Delete chunk directory and cleanup Redis
        try std.fs.cwd().deleteTree(chunk_dir);
        try self.redis_client.deleteSession(session.file_id);
    }

    fn validateAuth(r: zap.Request) !void {
        const auth_header = r.getHeader("authorization") orelse {
            return val.UploadError.Unauthorized;
        };

        if (auth_header.len <= 7 or !std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return val.UploadError.Unauthorized;
        }

        const token = auth_header[7..];
        if (!val.API_TOKENS.isValid(token)) {
            return val.UploadError.Unauthorized;
        }
    }

    fn addCorsHeaders(r: zap.Request) !void {
        try r.setHeader("Access-Control-Allow-Origin", "*");
        try r.setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
        try r.setHeader("Access-Control-Allow-Headers", "Content-Type, X-File-Id, X-Chunk-Index, Accept, Authorization");
        try r.setHeader("Access-Control-Expose-Headers", "Authorization");
    }

    fn sendErrorJson(r: zap.Request, err: anyerror, code: u16) void {
        r.setStatus(@enumFromInt(code));
        r.setHeader("Content-Type", "application/json") catch return;

        const error_msg = switch (err) {
            val.UploadError.InvalidRequestBody => "Invalid request body",
            val.UploadError.FileTooLarge => "File too large",
            val.UploadError.FileIdGenerationFailed => "Failed to generate file ID",
            val.UploadError.CreateSessionFailed => "Failed to create upload session",
            val.UploadError.StoreSessionFailed => "Failed to store session",
            val.UploadError.MissingFileId => "Missing file ID",
            val.UploadError.MissingChunkIndex => "Missing chunk index",
            val.UploadError.MissingChunkData => "Missing chunk data",
            val.UploadError.FileSizeExceeded => "File size exceeded",
            val.UploadError.WriteChunkFailed => "Failed to write chunk",
            val.UploadError.FinalizeUploadFailed => "Failed to finalize upload",
            val.UploadError.InvalidSession => "Invalid session",
            val.UploadError.Unauthorized => "Unauthorized",
            val.UploadError.RedisError => "Redis operation failed",
            else => "Internal server error",
        };

        // Create JSON string manually since we have a simple structure
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"status\":\"error\",\"error\":\"{s}\",\"code\":{d}}}", .{ error_msg, code }) catch {
            r.sendBody("{\"status\":\"error\",\"error\":\"Error formatting response\",\"code\":500}") catch return;
            return;
        };

        r.sendBody(json) catch return;
    }
};
