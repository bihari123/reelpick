const std = @import("std");
const zap = @import("zap");
const redis = @import("service/redis/redis_helper.zig");
const sqlite = @import("service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const val = @import("utils.zig");
const repo = @import("db.zig");
const server = @import("file_server.zig");
const utils = @import("utils.zig");
pub fn handleStatus(ep: *zap.Endpoint, r: zap.Request) void {
    const self: *server.FileServer = @fieldParentPtr("ep_status", ep);
    utils.addCorsHeaders(r) catch return;

    utils.validateAuth(r) catch |err| {
        if (err == val.UploadError.Unauthorized) {
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

    const session = self.redis_client.getSession(file_id) catch {
        utils.sendErrorJson(r, val.UploadError.InvalidSession, 400);
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

pub fn handleOptions(ep: *zap.Endpoint, r: zap.Request) void {
    _ = ep;
    utils.addCorsHeaders(r) catch return;
    r.setStatus(.no_content);
}
