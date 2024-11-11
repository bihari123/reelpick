const std = @import("std");
const zap = @import("zap");
const redis = @import("../../../service/redis/redis_helper.zig");
const sqlite = @import("../../../service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const opensearch = @import("../../../service/opensearch/opensearch_helper.zig");
const val = @import("./utils.zig");
const repo = @import("../repo/db.zig");
const server = @import("../../file_server.zig");
const utils = @import("./utils.zig");
pub fn handleInitialize(ep: *zap.Endpoint, r: zap.Request) void {
    const self: *server.FileServer = @fieldParentPtr("ep_initialize", ep);
    utils.addCorsHeaders(r) catch return;

    utils.validateAuth(r) catch |err| {
        if (err == val.UploadError.Unauthorized) {
            utils.sendErrorJson(r, val.UploadError.Unauthorized, 401);
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
            utils.sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
            return;
        };
        defer parsed.deinit();

        const init_data = parsed.value;

        if (init_data.fileSize > val.MAX_FILE_SIZE) {
            utils.sendErrorJson(r, val.UploadError.FileTooLarge, 400);
            return;
        }

        // Generate file ID
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var file_id_buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&file_id_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch {
            utils.sendErrorJson(r, val.UploadError.FileIdGenerationFailed, 500);
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
            utils.sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
            return;
        };
        defer session.deinit();

        // Store session in Redis
        self.redis_client.setSession(session) catch |err| {
            std.debug.print("error in storing session {!}", .{err});
            utils.sendErrorJson(r, val.UploadError.StoreSessionFailed, 500);
            return;
        };

        // Create chunk directory
        const chunk_dir = std.fs.path.join(
            self.allocator,
            &[_][]const u8{ val.UPLOAD_DIR, file_id },
        ) catch {
            utils.sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
            return;
        };
        defer self.allocator.free(chunk_dir);

        std.fs.cwd().makePath(chunk_dir) catch {
            utils.sendErrorJson(r, val.UploadError.CreateSessionFailed, 500);
            return;
        };

        {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            if (std.fmt.allocPrint(allocator, "{{\"directory\": \"{}\", \"file_name\": \"{s}\", \"file_size\": {any} }}", .{ std.zig.fmtEscapes(chunk_dir), init_data.fileName, init_data.fileSize })) |doc| {
                defer allocator.free(doc);
                // Get singleton instance
                if (opensearch.OpenSearchClient.getInstance(allocator, "0.0.0.0:9200")) |client| {
                    defer client.deinit();

                    // Index a document
                    client.index("initialize_upload", file_id, doc) catch {
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

// Test

const testing = std.testing;

// Mock FileServer for testing
const MockFileServer = struct {
    allocator: std.mem.Allocator,
    redis_client: *redis.RedisClient,
    ep_initialize: zap.Endpoint,

    pub fn init(allocator: std.mem.Allocator) !*MockFileServer {
        var self = try allocator.create(MockFileServer);
        self.allocator = allocator;
        self.redis_client = try redis.RedisClient.init(allocator, "localhost:6379");
        self.ep_initialize = zap.Endpoint.init(.{});
        return self;
    }

    pub fn deinit(self: *MockFileServer) void {
        self.redis_client.deinit();
        self.allocator.destroy(self);
    }
};

// Mock Request for testing
fn createMockRequest(allocator: std.mem.Allocator, body: ?[]const u8) !zap.Request {
    return zap.Request{
        .allocator = allocator,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = body,
        .response_sent = false,
    };
}

test "handleInitialize - valid request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create mock server
    var test_server = try MockFileServer.init(allocator);
    defer test_server.deinit();

    // Create valid request body
    const request_body =
        \\{
        \\    "fileName": "test.txt",
        \\    "fileSize": 1000,
        \\    "totalChunks": 2
        \\}
    ;

    var request = try createMockRequest(allocator, request_body);
    defer request.deinit();

    // Add auth header
    try request.headers.put("Authorization", "Bearer valid-token");

    // Call the function
    handleInitialize(&test_server.ep_initialize, request);

    // Verify response was sent
    try testing.expect(request.response_sent);

    // Parse response and verify fields
    const response = try std.json.parseFromSlice(struct {
        fileId: []const u8,
        fileName: []const u8,
        fileSize: usize,
        totalChunks: usize,
        chunkSize: usize,
    }, allocator, request.sent_body.?, .{});
    defer response.deinit();

    try testing.expectEqualStrings("test.txt", response.value.fileName);
    try testing.expectEqual(@as(usize, 1000), response.value.fileSize);
    try testing.expect(response.value.fileId.len > 0);
}

test "handleInitialize - file too large" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_server = try MockFileServer.init(allocator);
    defer test_server.deinit();

    // Create request with file size larger than MAX_FILE_SIZE
    const request_body =
        \\{
        \\    "fileName": "large.txt",
        \\    "fileSize": 999999999999,
        \\    "totalChunks": 2
        \\}
    ;

    var request = try createMockRequest(allocator, request_body);
    defer request.deinit();
    try request.headers.put("Authorization", "Bearer valid-token");

    handleInitialize(&test_server.ep_initialize, request);

    try testing.expect(request.response_sent);
    try testing.expectEqual(@as(u16, 400), request.status_code);
}

test "handleInitialize - invalid auth" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_server = try MockFileServer.init(allocator);
    defer test_server.deinit();

    const request_body =
        \\{
        \\    "fileName": "test.txt",
        \\    "fileSize": 1000,
        \\    "totalChunks": 2
        \\}
    ;

    var request = try createMockRequest(allocator, request_body);
    defer request.deinit();
    // Don't add auth header
 handleInitialize(&test_server.ep_initialize, request);

    try testing.expect(request.response_sent);
    try testing.expectEqual(@as(u16, 401), request.status_code);
}

test "handleInitialize - invalid request body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_server = try MockFileServer.init(allocator);
    defer test_server.deinit();

    const request_body = "invalid json";

    var request = try createMockRequest(allocator, request_body);
    defer request.deinit();
    try request.headers.put("Authorization", "Bearer valid-token");

   handleInitialize(&test_server.ep_initialize, request);

    try testing.expect(request.response_sent);
    try testing.expectEqual(@as(u16, 400), request.status_code);
}

test "handleInitialize - redis session creation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_server = try MockFileServer.init(allocator);
    defer test_server.deinit();

    const request_body =
        \\{
        \\    "fileName": "test.txt",
        \\    "fileSize": 1000,
        \\    "totalChunks": 2
        \\}
    ;

    var request = try createMockRequest(allocator, request_body);
    defer request.deinit();
    try request.headers.put("Authorization", "Bearer valid-token");

    handleInitialize(&test_server.ep_initialize, request);

    // Parse response to get fileId
    const response = try std.json.parseFromSlice(struct {
        fileId: []const u8,
        fileName: []const u8,
        fileSize: usize,
        totalChunks: usize,
        chunkSize: usize,
    }, allocator, request.sent_body.?, .{});
    defer response.deinit();

    // Verify session exists in Redis
    const session = try test_server.redis_client.getSession(response.value.fileId);
    defer session.deinit();

    try testing.expectEqualStrings("test.txt", session.file_name);
    try testing.expectEqual(@as(usize, 1000), session.file_size);
}
