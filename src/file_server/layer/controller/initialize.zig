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
        self.redis_client.setSession(session) catch {
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
                if (opensearch.OpenSearchClient.getInstance(allocator, "http://localhost:9200")) |client| {
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
