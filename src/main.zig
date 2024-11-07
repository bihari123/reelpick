const std = @import("std");
const zap = @import("zap");
const redis_helper = @import("redis_helper.zig");

const UPLOAD_DIR = "uploads";
const MAX_FILE_SIZE = 1000 * 1024 * 1024; // 1GB
const CHUNK_SIZE = 1 * 1024 * 1024; // 1MB

const UploadError = error{
    InvalidRequestBody,
    FileTooLarge,
    FileIdGenerationFailed,
    CreateSessionFailed,
    MissingFileId,
    MissingChunkIndex,
    MissingChunkData,
    FileSizeExceeded,
    WriteChunkFailed,
    InvalidSession,
    Unauthorized,
};

const ChunkJob = struct {
    file_id: []const u8,
    chunk_index: usize,
    chunk_size: usize,
    total_chunks: usize,
    chunk_data: []const u8,

    pub fn toJson(self: ChunkJob, allocator: std.mem.Allocator) ![]const u8 {
        return std.json.stringifyAlloc(allocator, .{
            .file_id = self.file_id,
            .chunk_index = self.chunk_index,
            .chunk_size = self.chunk_size,
            .total_chunks = self.total_chunks,
        }, .{});
    }

    pub fn fromJson(json: []const u8, allocator: std.mem.Allocator) !ChunkJob {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();

        return ChunkJob{
            .file_id = try allocator.dupe(u8, parsed.value.object.get("file_id").?.string),
            .chunk_index = @intCast(parsed.value.object.get("chunk_index").?.integer),
            .chunk_size = @intCast(parsed.value.object.get("chunk_size").?.integer),
            .total_chunks = @intCast(parsed.value.object.get("total_chunks").?.integer),
            .chunk_data = undefined, // Set during processing
        };
    }
};

const UploadServer = struct {
    allocator: std.mem.Allocator,
    job_queue: *redis_helper.RedisJobQueue,
    listener: *zap.Endpoint.Listener,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, port: u16) !*UploadServer {
        // Initialize Redis job queue
        const job_queue = try redis_helper.RedisJobQueue.init(allocator, "localhost", 6379, 3);

        // Create upload directory
        try std.fs.cwd().makePath(UPLOAD_DIR);

        // Initialize HTTP listener
        var listener = try zap.Endpoint.Listener.init(allocator, .{
            .port = port,
            .on_request = null,
            .log = true,
            .max_body_size = MAX_FILE_SIZE,
        });

        const server = try allocator.create(UploadServer);
        server.* = .{
            .allocator = allocator,
            .job_queue = job_queue,
            .listener = listener,
            .port = port,
        };

        // Register endpoints
        try listener.register(&(try zap.Endpoint.create(.{
            .path = "/api/upload/initialize",
            .post = handleInitialize,
            .userdata = server,
        })));

        try listener.register(&(try zap.Endpoint.create(.{
            .path = "/api/upload/chunk",
            .post = handleChunk,
            .userdata = server,
        })));

        try listener.register(&(try zap.Endpoint.create(.{
            .path = "/api/upload/status",
            .get = handleStatus,
            .userdata = server,
        })));

        // Start chunk processing workers
        const worker_count = 4;
        var i: usize = 0;
        while (i < worker_count) : (i += 1) {
            try std.Thread.spawn(.{}, processChunks, .{server});
        }

        return server;
    }

    pub fn start(self: *UploadServer) !void {
        try self.listener.listen();
        std.debug.print("Server listening on port {d}\n", .{self.port});

        zap.start(.{
            .threads = 4,
            .workers = 1,
        });
    }

    pub fn deinit(self: *UploadServer) void {
        self.job_queue.deinit();
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    fn handleInitialize(e: *zap.Endpoint, r: zap.Request) void {
        const server = @ptrCast(*UploadServer, @alignCast(@alignOf(*UploadServer), e.userdata));
        
        if (r.body) |body| {
            const parsed = std.json.parseFromSlice(struct {
                fileName: []const u8,
                fileSize: usize,
            }, server.allocator, body, .{}) catch {
                sendErrorJson(r, UploadError.InvalidRequestBody, 400);
                return;
            };
            defer parsed.deinit();

            const init_data = parsed.value;
            if (init_data.fileSize > MAX_FILE_SIZE) {
                sendErrorJson(r, UploadError.FileTooLarge, 400);
                return;
            }

            const file_id = generateFileId(server.allocator) catch {
                sendErrorJson(r, UploadError.FileIdGenerationFailed, 500);
                return;
            };

            const total_chunks = (init_data.fileSize + CHUNK_SIZE - 1) / CHUNK_SIZE;

            // Create file metadata
            const metadata = redis_helper.FileMetadata{
                .file_id = file_id,
                .file_name = init_data.fileName,
                .total_size = init_data.fileSize,
                .total_chunks = total_chunks,
                .completed_chunks = 0,
                .upload_status = .pending,
            };

            server.job_queue.storeFileMetadata(metadata) catch {
                sendErrorJson(r, redis_helper.JobError.InvalidMetadata, 500);
                return;
            };

            // Send response
            const response = .{
                .fileId = file_id,
                .fileName = init_data.fileName,
                .fileSize = init_data.fileSize,
                .chunkSize = CHUNK_SIZE,
                .totalChunks = total_chunks,
            };

            r.sendJson(response) catch return;
        }
    }

    fn handleChunk(e: *zap.Endpoint, r: zap.Request) void {
        const server = @ptrCast(*UploadServer, @alignCast(@alignOf(*UploadServer), e.userdata));

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, UploadError.MissingFileId, 400);
            return;
        };

        const chunk_index = r.getHeader("x-chunk-index") orelse {
            sendErrorJson(r, UploadError.MissingChunkIndex, 400);
            return;
        };

        const chunk_data = r.body orelse {
            sendErrorJson(r, UploadError.MissingChunkData, 400);
            return;
        };

        // Get file metadata
        const metadata = server.job_queue.getFileMetadata(file_id) catch |err| {
            sendErrorJson(r, err, 500);
            return;
        } orelse {
            sendErrorJson(r, redis_helper.JobError.InvalidMetadata, 400);
            return;
        };

        // Create and queue chunk job
        const chunk_index_num = std.fmt.parseInt(usize, chunk_index, 10) catch {
            sendErrorJson(r, UploadError.InvalidRequestBody, 400);
            return;
        };

        const chunk_job = ChunkJob{
            .file_id = file_id,
.chunk_index = chunk_index_num,
            .chunk_size = chunk_data.len,
            .total_chunks = metadata.total_chunks,
            .chunk_data = chunk_data,
        };

        // Convert to job and queue it
        const job_data = chunk_job.toJson(server.allocator) catch {
            sendErrorJson(r, redis_helper.JobError.InvalidJobData, 500);
            return;
        };
        defer server.allocator.free(job_data);

        const job = redis_helper.Job.init(
            server.allocator, 
            file_id, 
            .chunk_upload,
            job_data
        ) catch {
            sendErrorJson(r, redis_helper.JobError.InvalidJobData, 500);
            return;
        };
        defer job.deinit();

        server.job_queue.pushJob(job) catch {
            sendErrorJson(r, redis_helper.JobError.QueueFull, 500);
            return;
        };

        // Calculate current progress
        const progress = server.job_queue.getUploadProgress(file_id) catch |err| {
            sendErrorJson(r, err, 500);
            return;
        } orelse {
            sendErrorJson(r, redis_helper.JobError.InvalidMetadata, 400);
            return;
        };

        const response = .{
            .received = true,
            .status = "processing",
            .progress = @floatToInt(u8, (@intToFloat(f32, progress.completed) / @intToFloat(f32, progress.total)) * 100),
            .chunksReceived = progress.completed,
            .totalChunks = progress.total,
            .message = "chunk queued for processing",
        };

        r.sendJson(response) catch return;
    }

    fn handleStatus(e: *zap.Endpoint, r: zap.Request) void {
        const server = @ptrCast(*UploadServer, @alignCast(@alignOf(*UploadServer), e.userdata));

        const file_id = r.getHeader("x-file-id") orelse {
            sendErrorJson(r, UploadError.MissingFileId, 400);
            return;
        };

        const metadata = server.job_queue.getFileMetadata(file_id) catch |err| {
            sendErrorJson(r, err, 500);
            return;
        } orelse {
            sendErrorJson(r, redis_helper.JobError.InvalidMetadata, 400);
            return;
        };

        const progress = @floatToInt(u8, (@intToFloat(f32, metadata.completed_chunks) / @intToFloat(f32, metadata.total_chunks)) * 100);

        const response = .{
            .fileId = metadata.file_id,
            .fileName = metadata.file_name,
            .status = @tagName(metadata.upload_status),
            .progress = progress,
            .completedChunks = metadata.completed_chunks,
            .totalChunks = metadata.total_chunks,
            .totalSize = metadata.total_size,
        };

        r.sendJson(response) catch return;
    }

    fn processChunks(server: *UploadServer) !void {
        while (true) {
            if (try server.job_queue.getNextJob()) |job| {
                if (job.job_type == .chunk_upload) {
                    const chunk_job = try ChunkJob.fromJson(job.data, server.allocator);
                    
                    // Create chunk directory
                    const chunk_dir = try std.fs.path.join(server.allocator, 
                        &[_][]const u8{ UPLOAD_DIR, chunk_job.file_id });
                    defer server.allocator.free(chunk_dir);
                    
                    try std.fs.cwd().makePath(chunk_dir);
                    
                    // Write chunk to file
                    const chunk_filename = try std.fmt.allocPrint(server.allocator, 
                        "chunk_{d}", .{chunk_job.chunk_index});
                    defer server.allocator.free(chunk_filename);
                    
                    const chunk_path = try std.fs.path.join(server.allocator,
                        &[_][]const u8{ chunk_dir, chunk_filename });
                    defer server.allocator.free(chunk_path);
                    
                    const chunk_file = try std.fs.createFileAbsolute(chunk_path, .{});
                    defer chunk_file.close();
                    
                    try chunk_file.writeAll(chunk_job.chunk_data);
                    
                    // Update job status
                    try server.job_queue.updateJobStatus(job.id, .completed);
                    try server.job_queue.updateChunkStatus(chunk_job.file_id, chunk_job.chunk_index, true);
                    
                    // Check if all chunks are complete
                    if (try server.job_queue.getFileMetadata(chunk_job.file_id)) |metadata| {
                        if (metadata.completed_chunks == metadata.total_chunks) {
                            try assembleFile(server, metadata);
                        }
                    }
                }
                job.deinit();
            }
            
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn assembleFile(server: *UploadServer, metadata: redis_helper.FileMetadata) !void {
        const final_path = try std.fs.path.join(server.allocator,
            &[_][]const u8{ UPLOAD_DIR, metadata.file_name });
        defer server.allocator.free(final_path);

        const final_file = try std.fs.createFileAbsolute(final_path, .{});
        defer final_file.close();

        const chunk_dir = try std.fs.path.join(server.allocator,
            &[_][]const u8{ UPLOAD_DIR, metadata.file_id });
        defer server.allocator.free(chunk_dir);

        var i: usize = 0;
        while (i < metadata.total_chunks) : (i += 1) {
            const chunk_filename = try std.fmt.allocPrint(server.allocator,
                "chunk_{d}", .{i});
            defer server.allocator.free(chunk_filename);

            const chunk_path = try std.fs.path.join(server.allocator,
                &[_][]const u8{ chunk_dir, chunk_filename });
            defer server.allocator.free(chunk_path);

            const chunk_file = try std.fs.openFileAbsolute(chunk_path, .{});
            defer chunk_file.close();

            var buffer: [8192]u8 = undefined;
            while (true) {
                const bytes_read = try chunk_file.read(&buffer);
                if (bytes_read == 0) break;
                try final_file.writeAll(buffer[0..bytes_read]);
            }
        }

        // Clean up chunk directory
        try std.fs.deleteTreeAbsolute(chunk_dir);
    }

    fn generateFileId(allocator: std.mem.Allocator) ![]const u8 {
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        const hex = "0123456789abcdef";
        var result = try allocator.alloc(u8, 32);
        errdefer allocator.free(result);

        for (random_bytes, 0..) |byte, i| {
            result[i * 2] = hex[byte >> 4];
            result[i * 2 + 1] = hex[byte & 15];
        }

        return result;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 8080;
    if (args.len > 1) {
        port = try std.fmt.parseInt(u16, args[1], 10);
    }

    // Check Redis connection first
    try redis_helper.checkRedisConnection();

    var server = try UploadServer.init(allocator, port);
    defer server.deinit();

    try server.start();
}

fn sendErrorJson(r: zap.Request, err: anyerror, code: u16) void {
    r.setStatus(@intToEnum(std.http.Status, code));
    
    const error_msg = switch (err) {
        UploadError.InvalidRequestBody => "Invalid request body",
        UploadError.FileTooLarge => "File too large",
        UploadError.FileIdGenerationFailed => "Failed to generate file ID",
        UploadError.CreateSessionFailed => "Failed to create upload session",
        UploadError.MissingFileId => "Missing file ID",
        UploadError.MissingChunkIndex => "Missing chunk index",
        UploadError.MissingChunkData => "Missing chunk data",
        UploadError.FileSizeExceeded => "File size exceeded",
        UploadError.WriteChunkFailed => "Failed to write chunk",
        UploadError.InvalidSession => "Invalid session",
        UploadError.Unauthorized => "Unauthorized",
        redis_helper.JobError.InvalidMetadata => "Invalid file metadata",
        redis_helper.JobError.InvalidJobData => "Invalid job data",
        redis_helper.JobError.QueueFull => "Upload queue is full",
        else => "Internal server error",
    };

    const response = .{
        .error = error_msg,
        .code = code,
    };

    r.sendJson(response) catch return;
}
