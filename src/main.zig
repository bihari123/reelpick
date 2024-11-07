const std = @import("std");
const zap = @import("zap");

// File upload settings
const UPLOAD_DIR = "uploads";
const MAX_FILE_SIZE = 1000 * 1024 * 1024; // 500MB

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
};

const UploadSession = struct {
    file_id: []const u8,
    file_name: []const u8,
    total_size: usize,
    uploaded_size: usize,
    file: std.fs.File,
    last_activity: i64,

    pub fn init(alloc: std.mem.Allocator, file_id: []const u8, file_name: []const u8, total_size: usize) !UploadSession {
        // Create a safe file path by joining directory and file_id
        //var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const file_path = try std.fs.path.join(alloc, &[_][]const u8{ UPLOAD_DIR, file_id });
        defer alloc.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});

        return UploadSession{
            .file_id = try alloc.dupe(u8, file_id),
            .file_name = try alloc.dupe(u8, file_name),
            .total_size = total_size,
            .uploaded_size = 0,
            .file = file,
            .last_activity = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *UploadSession, alloc: std.mem.Allocator) void {
        self.file.close();
        alloc.free(self.file_id);
        alloc.free(self.file_name);
    }
};

const UploadEndpoint = struct {
    alloc: std.mem.Allocator,
    sessions: std.StringHashMap(UploadSession),
    lock: std.Thread.Mutex,
    ep_initialize: zap.Endpoint,
    ep_chunk: zap.Endpoint,

    pub fn init(alloc: std.mem.Allocator) !UploadEndpoint {
        try std.fs.cwd().makePath(UPLOAD_DIR);

        return UploadEndpoint{
            .alloc = alloc,
            .sessions = std.StringHashMap(UploadSession).init(alloc),
            .lock = .{},
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
        };
    }

    pub fn deinit(self: *UploadEndpoint) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.sessions.deinit();
    }

    fn generateFileId(alloc: std.mem.Allocator) ![]const u8 {
        // Generate a UUID-style identifier
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        // Convert to hex string
        const hex = "0123456789abcdef";
        var result = try alloc.alloc(u8, 32);

        for (random_bytes, 0..) |byte, i| {
            result[i * 2] = hex[byte >> 4];
            result[i * 2 + 1] = hex[byte & 15];
        }

        return result;
    }
    fn addCorsHeaders(r: zap.Request) !void {
        try r.setHeader("Access-Control-Allow-Origin", "*");
        try r.setHeader("Access-Control-Allow-Methods", "POST, PUT, OPTIONS");
        try r.setHeader("Access-Control-Allow-Headers", "Content-Type, X-File-Id, X-Chunk-Index");
    }
    fn handleOptions(ep: *zap.Endpoint, r: zap.Request) void {
        _ = ep;
        addCorsHeaders(r) catch return;
        r.setStatus(.no_content);
        r.markAsFinished(true);
    }
    fn handleInitialize(ep: *zap.Endpoint, r: zap.Request) void {
        addCorsHeaders(r) catch return;

        const self: *UploadEndpoint = @fieldParentPtr("ep_initialize", ep);

        if (r.body) |body| {
            const parsed = std.json.parseFromSlice(struct {
                fileName: []const u8,
                fileSize: usize,
                totalChunks: usize,
            }, self.alloc, body, .{}) catch {
                r.sendError(UploadError.InvalidRequestBody, null, 400);
                return;
            };
            defer parsed.deinit();

            const init_data = parsed.value;

            if (init_data.fileSize > MAX_FILE_SIZE) {
                r.sendError(UploadError.FileTooLarge, null, 400);
                return;
            }

            const file_id = generateFileId(self.alloc) catch {
                r.sendError(UploadError.FileIdGenerationFailed, null, 500);
                return;
            };
            defer self.alloc.free(file_id);

            self.lock.lock();
            defer self.lock.unlock();

            const session = UploadSession.init(self.alloc, file_id, init_data.fileName, init_data.fileSize) catch {
                r.sendError(UploadError.CreateSessionFailed, null, 500);
                return;
            };

            self.sessions.put(session.file_id, session) catch {
                r.sendError(UploadError.StoreSessionFailed, null, 500);
                return;
            };

            // Prepare response
            r.setHeader("Content-Type", "application/json") catch return;
            const response = .{
                .fileId = session.file_id,
                .fileName = session.file_name,
                .fileSize = session.total_size,
            };

            var json_buf: [1024]u8 = undefined;
            const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
                r.sendError(UploadError.InvalidRequestBody, null, 500);
                return;
            };
            r.sendBody(json) catch return;
        }
    }

    fn handleChunk(ep: *zap.Endpoint, r: zap.Request) void {
        addCorsHeaders(r) catch return;

        const self: *UploadEndpoint = @fieldParentPtr("ep_chunk", ep);

        std.debug.print("\n=== Request Headers ===\n", .{});

        // Create our header print callback
        const PrintContext = struct {
            fn printHeader(fiobj_value: zap.fio.FIOBJ, context: ?*anyopaque) callconv(.C) c_int {
                _ = context;
                // Get the header key (this is thread-safe, guaranteed by fio)
                const fiobj_key = zap.fio.fiobj_hash_key_in_loop();

                if (zap.fio2str(fiobj_key)) |key| {
                    if (zap.fio2str(fiobj_value)) |value| {
                        std.debug.print("{s}: {s}\n", .{ key, value });
                    }
                }
                return 0;
            }
        };

        // Iterate through all headers using fio.fiobj_each1
        _ = zap.fio.fiobj_each1(r.h.*.headers, 0, PrintContext.printHeader, null);

        const file_id = r.getHeader("x-file-id") orelse {
            // r.sendError(UploadError.MissingFileId, null, 400);
            sendErrorJson(r, UploadError.MissingFileId, 400);

            return;
        };

        const chunk_index = r.getHeader("x-chunk-index") orelse {
            //r.sendError(UploadError.MissingChunkIndex, null, 400);
            sendErrorJson(r, UploadError.MissingChunkIndex, 400);

            return;
        };

        const chunk_data = r.body orelse {
            // r.sendError(UploadError.MissingChunkData, null, 400);
            sendErrorJson(r, UploadError.MissingChunkData, 400);

            return;
        };
        std.debug.print("FIleId: {s}, chunk_index {u}", .{ file_id, chunk_index });
        self.lock.lock();
        defer self.lock.unlock();

        if (self.sessions.getPtr(file_id)) |session| {
            if (session.uploaded_size + chunk_data.len > session.total_size) {
                // r.sendError(UploadError.FileSizeExceeded, null, 400);
                sendErrorJson(r, UploadError.FileSizeExceeded, 400);
                return;
            }

            session.file.writeAll(chunk_data) catch {
                r.sendError(UploadError.WriteChunkFailed, null, 500);
                return;
            };

            session.uploaded_size += chunk_data.len;
            session.last_activity = std.time.timestamp();

            const progress = @as(f32, @floatFromInt(session.uploaded_size)) /
                @as(f32, @floatFromInt(session.total_size)) * 100.0;

            const response = .{
                .received = true,
                .status = if (progress < 30) "analyzing" else if (progress < 60) "processing" else if (progress < 100) "finalizing" else "done",
                .progress = @as(u8, @intFromFloat(progress)),
                .uploadedSize = session.uploaded_size,
                .totalSize = session.total_size,
                .message = "chunk upload successful",
            };

            var json_buf: [1024]u8 = undefined;
            const json = zap.stringifyBuf(&json_buf, response, .{}) orelse {
                r.sendError(UploadError.InvalidRequestBody, null, 500);
                return;
            };

            if (session.uploaded_size >= session.total_size) {
                const cwd = std.fs.cwd();

                const src_path = std.fs.path.join(self.alloc, &[_][]const u8{ UPLOAD_DIR, session.file_id }) catch {
                    r.sendError(UploadError.FinalizeUploadFailed, null, 500);
                    return;
                };
                defer self.alloc.free(src_path);

                const dst_path = std.fs.path.join(self.alloc, &[_][]const u8{ UPLOAD_DIR, session.file_name }) catch {
                    r.sendError(UploadError.FinalizeUploadFailed, null, 500);
                    return;
                };
                defer self.alloc.free(dst_path);

                std.fs.rename(cwd, src_path, cwd, dst_path) catch {
                    r.sendError(UploadError.FinalizeUploadFailed, null, 500);
                    return;
                };

                _ = self.sessions.remove(file_id);
                //   session.deinit(self.alloc);
            }

            r.sendJson(json) catch return;
        } else {
            r.sendError(UploadError.InvalidSession, null, 400);
            return;
        }
    }
    fn sendErrorJson(r: zap.Request, err: UploadError, code: u16) void {
        // Set headers first
        r.setStatus(@enumFromInt(code));
        r.setHeader("Content-Type", "application/json") catch return;

        // Build error response based on the error type
        const error_msg: []const u8 = switch (err) {
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
        };

        // Create JSON string manually since we have a simple structure
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"status\":\"error\",\"error\":\"{s}\",\"code\":{d}}}", .{ error_msg, code }) catch {
            r.sendBody("{\"status\":\"error\",\"error\":\"Error formatting response\",\"code\":500}") catch return;
            return;
        };

        r.sendBody(json) catch return;
    }

    pub fn endpoints(self: *UploadEndpoint) [2]*zap.Endpoint {
        return .{ &self.ep_initialize, &self.ep_chunk };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    const allocator = gpa.allocator();

    var upload_endpoint = try UploadEndpoint.init(allocator);
    defer upload_endpoint.deinit();

    var listener = zap.Endpoint.Listener.init(allocator, .{
        .port = 8080,
        .on_request = null,
        .log = true,
        .max_body_size = MAX_FILE_SIZE,
    });

    // Register both endpoints
    for (upload_endpoint.endpoints()) |ep| {
        try listener.register(ep);
    }

    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:8080\n", .{});

    zap.start(.{
        .threads = 4,
        .workers = 1,
    });
}
