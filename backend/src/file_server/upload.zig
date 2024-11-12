const std = @import("std");
const zap = @import("zap");
const redis = @import("service/redis/redis_helper.zig");
const sqlite = @import("service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const val = @import("utils.zig");
const repo = @import("db.zig");
const server = @import("file_server.zig");
const utils = @import("utils.zig");
const opensearch = @import("service/opensearch/opensearch_helper.zig");

pub fn handleChunk(ep: *zap.Endpoint, r: zap.Request) void {
    const self: *server.FileServer = @fieldParentPtr("ep_chunk", ep);
    utils.addCorsHeaders(r) catch return;

    utils.validateAuth(r) catch |err| {
        if (err == val.UploadError.Unauthorized) {
            std.debug.print("Invalid token", .{});
            utils.sendErrorJson(r, val.UploadError.Unauthorized, 401);
            return;
        }
        r.sendError(err, null, 500);
        return;
    };

    const file_id = r.getHeader("x-file-id") orelse {
        utils.sendErrorJson(r, val.UploadError.MissingFileId, 400);
        return;
    };

    const chunk_index_str = r.getHeader("x-chunk-index") orelse {
        utils.sendErrorJson(r, val.UploadError.MissingChunkIndex, 400);
        return;
    };

    const chunk_index = std.fmt.parseInt(usize, chunk_index_str, 10) catch {
        utils.sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
        return;
    };

    const chunk_data = r.body orelse {
        utils.sendErrorJson(r, val.UploadError.MissingChunkData, 400);
        return;
    };

    // Get session from Redis
    const session = self.redis_client.getSession(file_id) catch {
        utils.sendErrorJson(r, val.UploadError.InvalidSession, 400);
        return;
    };
    defer session.deinit();

    // Validate chunk size and index
    if (chunk_index >= session.total_chunks) {
        utils.sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
        return;
    }

    // Write chunk to file
    const chunk_dir = std.fs.path.join(
        self.allocator,
        &[_][]const u8{ val.UPLOAD_DIR, file_id },
    ) catch {
        utils.sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
        return;
    };
    defer self.allocator.free(chunk_dir);

    const chunk_path = std.fmt.allocPrint(
        self.allocator,
        "{s}/chunk_{d}",
        .{ chunk_dir, chunk_index },
    ) catch {
        utils.sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
        return;
    };
    defer self.allocator.free(chunk_path);

    const chunk_file = std.fs.cwd().createFile(chunk_path, .{}) catch {
        utils.sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
        return;
    };
    defer chunk_file.close();

    chunk_file.writeAll(chunk_data) catch {
        utils.sendErrorJson(r, val.UploadError.WriteChunkFailed, 500);
        return;
    };
    {
        const total_chunks = std.math.cast(i64, session.total_chunks) orelse 0;
        const uploaded_chunks = std.math.cast(i64, session.uploaded_chunks) orelse 0;
        //pub fn update_chunk_table(file_id: []u8, total_chunks: i64, uploaded_chunks: i64, chunk_path: []u8) void
        repo.update_chunk_table(file_id, total_chunks, uploaded_chunks, chunk_path);
    }
    // Update session in Redis
    self.redis_client.updateChunkStatus(file_id, chunk_index, chunk_data.len) catch {
        utils.sendErrorJson(r, val.UploadError.RedisError, 500);
        return;
    };

    // Get updated session for response
    const updated_session = self.redis_client.getSession(file_id) catch {
        utils.sendErrorJson(r, val.UploadError.RedisError, 500);
        return;
    };
    defer updated_session.deinit();

    // Check if all chunks are uploaded and finalize if needed
    if (updated_session.uploaded_chunks == updated_session.total_chunks) {
        utils.finalizeUpload(self, updated_session) catch |err| {
            utils.sendErrorJson(r, err, 500);
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
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        if (std.fmt.allocPrint(allocator, "{{\"chunk_path\": \"{}\", \"file_name\": \"{s}\", \"chunk_index\": {any} }}", .{ std.zig.fmtEscapes(chunk_path), session.file_name, chunk_index })) |doc| {
            defer allocator.free(doc);
            // Get singleton instance
            if (opensearch.OpenSearchClient.getInstance(allocator, "0.0.0.0:9200")) |client| {
                defer client.deinit();

                if (std.fmt.allocPrint(allocator, "{s}_{d}", .{ file_id, chunk_index })) |doc_id| {
                    defer allocator.free(doc_id);

                    // Index a document
                    client.index("chunk_upload", doc_id, doc) catch {
                        std.debug.print("can't index opensearch ", .{});
                    };
                } else |err| {
                    std.debug.print("error making doc id {!}\n", .{err});
                }
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
            std.debug.print("error in preparing opensearch statement {!}\n", .{err});
        }
    }
}
