const std = @import("std");
const zap = @import("zap");
const redis = @import("./layer/service/redis/redis_helper.zig");

// File upload settings
const UPLOAD_DIR = "uploads";
const MAX_FILE_SIZE = 1000 * 1024 * 1024; // 1000MB
const CHUNK_SIZE = 1024 * 1024; // 1MB

const UploadError = error{
    InvalidRequestBody,
    FileTooLarge,
    FileIdGenerationFailed,
    CreateSessionFailed,
    StoreSessionFailed,
    MissingFileId,
    MissingChunkIndex,
    MissingChunkData,
    FileSizeExceeded,
    WriteChunkFailed,
    FinalizeUploadFailed,
    InvalidSession,
    Unauthorized,
    RedisError,
};

// API token validation
const API_TOKENS = struct {
    const tokens = [_][]const u8{
        "tk_1234567890abcdef",
        "tk_0987654321fedcba",
    };

    pub fn isValid(token: []const u8) bool {
        for (tokens) |valid_token| {
            if (std.mem.eql(u8, token, valid_token)) {
                return true;
            }
        }
        return false;
    }
};

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    redis_client: redis.RedisClient,
    ep_initialize: zap.Endpoint,
    ep_chunk: zap.Endpoint,
    ep_status: zap.Endpoint,

    pub fn init(allocator: std.mem.Allocator) !*FileServer {
        // Create uploads directory
        try std.fs.cwd().makePath(UPLOAD_DIR);

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
            .max_body_size = MAX_FILE_SIZE,
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
            if (err == UploadError.Unauthorized) {
                sendErrorJson(r, UploadError.Unauthorized, 401);
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
                sendErrorJson(r, UploadError.InvalidRequestBody, 400);
                return;
            };
            defer parsed.deinit();

            const init_data = parsed.value;

            if (init_data.fileSize > MAX_FILE_SIZE) {
                sendErrorJson(r, UploadError.FileTooLarge, 400);
                return;
            }

            // Generate file ID
            var random_bytes: [16]u8 = undefined;
            std.crypto.random.bytes(&random_bytes);
            var file_id_buf: [32]u8 = undefined;
            _ = std.fmt.bufPrint(&file_id_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch {
                sendErrorJson(r, UploadError.FileIdGenerationFailed, 500);
                return;
            };
            const file_id = file_id_buf[0..];

            // Create upload session
            const session = redis.UploadSession.init(
                self.allocator,
                file_id,
                init_data.fileName,
                init_data.fileSize,
                CHUNK_SIZE,
            ) catch {
                sendErrorJson(r, UploadError.CreateSessionFailed, 500);
                return;
            };
            defer session.deinit();

            // Store session in Redis
            self.redis_client.setSession(session) catch {
                sendErrorJson(r, UploadError.StoreSessionFailed, 500);
                return;
            };

            // Create chunk directory
            const chunk_dir = std.fs.path.join(
                self.allocator,
                &[_][]const u8{ UPLOAD_DIR, file_id },
            ) catch {
                sendErrorJson(r, UploadError.CreateSessionFailed, 500);
                return;
            };
            defer self.allocator.free(chunk_dir);

            std.fs.cwd().makePath(chunk_dir) catch {
                sendErrorJson(r, UploadError.CreateSessionFailed, 500);
                return;
            };

            // Send response
            const response = .{
                .fileId = file_id,
                .fileName = init_data.fileName,
                .fileSize = init_data.fileSize,
                .totalChunks = session.total_chunks,
                .chunkSize = CHUNK_SIZE,
            };

            // r.sendJson(response) catch {
            //         sendErrorJson(r, UploadError.InvalidRequestBody, 500);
            //         return;
            //     };
            var json_buf: [1024]u8 = undefined;
            const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
                r.sendError(UploadError.InvalidRequestBody, null, 500);
                return;
            };
            r.sendBody(json) catch return;
        }
    }

    fn handleChunk(ep: *zap.Endpoint, r: zap.Request) void {
        const self: *FileServer = @fieldParentPtr("ep_chunk", ep);
        addCorsHeaders(r) catch return;

        validateAuth(r) catch |err| {
            if (err == UploadError.Unauthorized) {
                std.debug.print("Invalid token", .{});
                sendErrorJson(r, UploadError.Unauthorized, 401);
                return;
            }
            r.sendError(err, null, 500);
            return;
        };

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, UploadError.MissingFileId, 400);
            return;
        };

        const chunk_index_str = r.getHeader("x-chunk-index") orelse {
            sendErrorJson(r, UploadError.MissingChunkIndex, 400);
            return;
        };

        const chunk_index = std.fmt.parseInt(usize, chunk_index_str, 10) catch {
            sendErrorJson(r, UploadError.InvalidRequestBody, 400);
            return;
        };

        const chunk_data = r.body orelse {
            sendErrorJson(r, UploadError.MissingChunkData, 400);
            return;
        };

        // Get session from Redis
        const session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, UploadError.InvalidSession, 400);
            return;
        };
        defer session.deinit();

        // Validate chunk size and index
        if (chunk_index >= session.total_chunks) {
            sendErrorJson(r, UploadError.InvalidRequestBody, 400);
            return;
        }

        // Write chunk to file
        const chunk_dir = std.fs.path.join(
            self.allocator,
            &[_][]const u8{ UPLOAD_DIR, file_id },
        ) catch {
            sendErrorJson(r, UploadError.WriteChunkFailed, 500);
            return;
        };
        defer self.allocator.free(chunk_dir);

        const chunk_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/chunk_{d}",
            .{ chunk_dir, chunk_index },
        ) catch {
            sendErrorJson(r, UploadError.WriteChunkFailed, 500);
            return;
        };
        defer self.allocator.free(chunk_path);

        const chunk_file = std.fs.cwd().createFile(chunk_path, .{}) catch {
            sendErrorJson(r, UploadError.WriteChunkFailed, 500);
            return;
        };
        defer chunk_file.close();

        chunk_file.writeAll(chunk_data) catch {
            sendErrorJson(r, UploadError.WriteChunkFailed, 500);
            return;
        };

        // Update session in Redis
        self.redis_client.updateChunkStatus(file_id, chunk_index, chunk_data.len) catch {
            sendErrorJson(r, UploadError.RedisError, 500);
            return;
        };

        // Get updated session for response
        const updated_session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, UploadError.RedisError, 500);
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
            r.sendError(UploadError.InvalidRequestBody, null, 500);
            return;
        };
        r.sendBody(json) catch return;
    }

    fn handleStatus(ep: *zap.Endpoint, r: zap.Request) void {
        const self: *FileServer = @fieldParentPtr("ep_status", ep);
        addCorsHeaders(r) catch return;

        validateAuth(r) catch |err| {
            if (err == UploadError.Unauthorized) {
                sendErrorJson(r, UploadError.Unauthorized, 401);
                return;
            }
            r.sendError(err, null, 500);
            return;
        };

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, UploadError.MissingFileId, 400);
            return;
        };

        const session = self.redis_client.getSession(file_id) catch {
            sendErrorJson(r, UploadError.InvalidSession, 400);
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
            r.sendError(UploadError.InvalidRequestBody, null, 500);
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
            &[_][]const u8{ UPLOAD_DIR, session.file_id },
        );
        defer self.allocator.free(chunk_dir);

        const final_path = try std.fs.path.join(
            self.allocator,
            &[_][]const u8{ UPLOAD_DIR, session.file_name },
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
                MAX_FILE_SIZE,
            );
            defer self.allocator.free(chunk_data);

            try final_file.writeAll(chunk_data);
            try std.fs.cwd().deleteFile(chunk_path);
        }

        // Delete chunk directory and cleanup Redis
        try std.fs.cwd().deleteTree(chunk_dir);
        try self.redis_client.deleteSession(session.file_id);
    }

    fn validateAuth(r: zap.Request) !void {
        const auth_header = r.getHeader("authorization") orelse {
            return UploadError.Unauthorized;
        };

        if (auth_header.len <= 7 or !std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return UploadError.Unauthorized;
        }

        const token = auth_header[7..];
        if (!API_TOKENS.isValid(token)) {
            return UploadError.Unauthorized;
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
            UploadError.InvalidRequestBody => "Invalid request body",
            UploadError.FileTooLarge => "File too large",
            UploadError.FileIdGenerationFailed => "Failed to generate file ID",
            UploadError.CreateSessionFailed => "Failed to create upload session",
            UploadError.StoreSessionFailed => "Failed to store session",
            UploadError.MissingFileId => "Missing file ID",
            UploadError.MissingChunkIndex => "Missing chunk index",
            UploadError.MissingChunkData => "Missing chunk data",
            UploadError.FileSizeExceeded => "File size exceeded",
            UploadError.WriteChunkFailed => "Failed to write chunk",
            UploadError.FinalizeUploadFailed => "Failed to finalize upload",
            UploadError.InvalidSession => "Invalid session",
            UploadError.Unauthorized => "Unauthorized",
            UploadError.RedisError => "Redis operation failed",
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

pub fn main() !void {
    // Initialize general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize server
    var server = try FileServer.init(allocator);
    defer server.deinit();

    // Start server
    const port: u16 = 8080;
    std.debug.print("Starting file server on port {d}...\n", .{port});
    try server.start(port);
}
