const std = @import("std");
const zap = @import("zap");
const redis = @import("service/redis/redis_helper.zig");
const sqlite = @import("service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const repo = @import("db.zig");
const server = @import("file_server.zig");
const opensearch = @import("service/opensearch/opensearch_helper.zig");
// File upload settings
pub const UPLOAD_DIR = "uploads";
pub const MAX_FILE_SIZE = 1000 * 1024 * 1024; // 1000MB
pub const CHUNK_SIZE = 1024 * 1024; // 1MB

pub const UploadError = error{
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
    TrimError,
    JoinError,
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

pub fn finalizeUpload(self: *server.FileServer, session: *redis.UploadSession) !void {
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

    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        if (std.fmt.allocPrint(allocator, "{{\"directory\": \"{}\", \"file_name\": \"{s}\", \"file_size\": {any},  \"total_chunks\": {any} }}", .{ std.zig.fmtEscapes(final_path), session.file_name, session.total_size, session.total_chunks })) |doc| {
            defer allocator.free(doc);
            // Get singleton instance
            if (opensearch.OpenSearchClient.getInstance(allocator, "0.0.0.0:9200")) |client| {
                defer client.deinit();

                // Index a document
                client.index("complete_upload", session.file_id, doc) catch {
                    std.debug.print("can't index opensearch ", .{});
                };
            } else |err| {
                switch (err) {
                    opensearch.OpenSearchError.RequestError => {
                        std.debug.print("Failed to connect to OpenSearch: {!}\n", .{err});
                    },
                    opensearch.OpenSearchError.URLError => {
                        std.debug.print("Invalid URL provided: {!}\n", .{err});
                    },
                    else => {
                        std.debug.print("Unexpected error: {!}\n", .{err});
                    },
                }
            }
        } else |err| {
            std.debug.print("error in preparing opensearch statement {!}", .{err});
        }
    }

    // Delete chunk directory and cleanup Redis
    try std.fs.cwd().deleteTree(chunk_dir);
    try self.redis_client.deleteSession(session.file_id);
    {
        const file_size = std.math.cast(i64, final_file.getEndPos() catch 0) orelse 0;
        repo.update_final_table(session.file_id, file_size, final_path);
    }
}

pub fn validateAuth(r: zap.Request) !void {
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

pub fn addCorsHeaders(r: zap.Request) !void {
    try r.setHeader("Access-Control-Allow-Origin", "*");
    try r.setHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
    try r.setHeader("Access-Control-Allow-Headers", "Content-Type, X-File-Id, X-Chunk-Index, Accept, Authorization");
    try r.setHeader("Access-Control-Expose-Headers", "Authorization");
}

pub fn sendErrorJson(r: zap.Request, err: anyerror, code: u16) void {
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

