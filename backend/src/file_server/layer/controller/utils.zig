const std = @import("std");
const zap = @import("zap");
const redis = @import("../../../service/redis/redis_helper.zig");
const sqlite = @import("../../../service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const repo = @import("../repo/db.zig");
const server = @import("../../file_server.zig");
const opensearch = @import("../../../service/opensearch/opensearch_helper.zig");
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

// Test helpers
const MockRequest = struct {
    headers: std.StringHashMap([]const u8),
    status: u16,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockRequest {
        return .{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .status = 200,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockRequest) void {
        self.headers.deinit();
    }

    pub fn getHeader(self: *const MockRequest, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn setHeader(self: *MockRequest, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn setStatus(self: *MockRequest, new_status: u16) void {
        self.status = new_status;
    }

   
};

test "API token validation - valid token" {
    const valid_token = "tk_1234567890abcdef";
    try std.testing.expect(API_TOKENS.isValid(valid_token));
}

test "API token validation - invalid token" {
    const invalid_token = "invalid_token";
    try std.testing.expect(!API_TOKENS.isValid(invalid_token));
}

test "validateAuth - valid auth header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_request = MockRequest.init(allocator);
    defer mock_request.deinit();

    try mock_request.setHeader("authorization", "Bearer tk_1234567890abcdef");
    try validateAuth(&mock_request);
}

test "validateAuth - missing auth header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_request = MockRequest.init(allocator);
    defer mock_request.deinit();

    try std.testing.expectError(UploadError.Unauthorized, validateAuth(&mock_request));
}

test "validateAuth - invalid token format" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_request = MockRequest.init(allocator);
    defer mock_request.deinit();

    try mock_request.setHeader("authorization", "InvalidFormat");
    try std.testing.expectError(UploadError.Unauthorized, validateAuth(&mock_request));
}

test "addCorsHeaders" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_request = MockRequest.init(allocator);
    defer mock_request.deinit();

    try addCorsHeaders(&mock_request);

    const origin = mock_request.getHeader("Access-Control-Allow-Origin");
    try std.testing.expectEqualStrings("*", origin.?);

    const methods = mock_request.getHeader("Access-Control-Allow-Methods");
    try std.testing.expectEqualStrings("POST, GET, OPTIONS", methods.?);
}

test "sendErrorJson - unauthorized error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mock_request = MockRequest.init(allocator);
    defer mock_request.deinit();

    sendErrorJson(&mock_request, UploadError.Unauthorized, 401);
    try std.testing.expectEqual(@as(u16, 401), mock_request.status);
}

test "finalizeUpload - basic test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test directories
    try std.fs.cwd().makeDir(UPLOAD_DIR);
    defer std.fs.cwd().deleteTree(UPLOAD_DIR) catch {};

    // Create a mock session
    const test_file_id = "test_file_123";
    const test_file_name = "test_file.txt";
    var session = redis.UploadSession{
        .file_id = test_file_id,
        .file_name = test_file_name,
        .total_size = 100,
        .total_chunks = 1,
        .current_chunk = 0,
    };

    // Create test chunk directory and file
    const chunk_dir = try std.fs.path.join(allocator, &[_][]const u8{ UPLOAD_DIR, test_file_id });
    defer allocator.free(chunk_dir);
    try std.fs.cwd().makeDir(chunk_dir);

    const chunk_path = try std.fmt.allocPrint(allocator, "{s}/chunk_0", .{chunk_dir});
    defer allocator.free(chunk_path);

    // Write test data to chunk file
    const test_data = "Hello, World!";
    {
        const chunk_file = try std.fs.cwd().createFile(chunk_path, .{});
        defer chunk_file.close();
        try chunk_file.writeAll(test_data);
    }

    // Create mock FileServer
    var mock_server = server.FileServer.init(allocator);
    defer mock_server.deinit();

    // Test finalizeUpload
    try finalizeUpload(&mock_server, &session);

    // Verify the final file exists and contains correct data
    const final_path = try std.fs.path.join(allocator, &[_][]const u8{ UPLOAD_DIR, test_file_name });
    defer allocator.free(final_path);

    const file_contents = try std.fs.cwd().readFileAlloc(allocator, final_path, 1024);
    defer allocator.free(file_contents);

    try std.testing.expectEqualStrings(test_data, file_contents);
}