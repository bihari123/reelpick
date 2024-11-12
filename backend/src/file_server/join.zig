const std = @import("std");
const zap = @import("zap");
const redis = @import("service/redis/redis_helper.zig");
const sqlite = @import("service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const val = @import("utils.zig");
const repo = @import("db.zig");
const server = @import("file_server.zig");
const utils = @import("utils.zig");
const video = @import("service/ffmpeg/ffmpeg_helper.zig");

pub fn handleJoin(ep: *zap.Endpoint, r: zap.Request) void {
    std.debug.print("inside join\n", .{});
    const self: *server.FileServer = @fieldParentPtr("ep_join", ep);
    utils.addCorsHeaders(r) catch return;

    utils.validateAuth(r) catch |err| {
        if (err == val.UploadError.Unauthorized) {
            std.debug.print("Invalid token\n", .{});
            utils.sendErrorJson(r, val.UploadError.Unauthorized, 401);
            return;
        }
        r.sendError(err, null, 500);
        return;
    };

    if (r.body) |body| {
        // Define request structure
        const JoinRequest = struct {
            parts: []const []const u8,
            outputFile: []const u8, // Changed from []u8 to []const u8
        };

        // // Create an arena allocator for temporary allocations
        // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // defer arena.deinit();
        // const arena_allocator = arena.allocator();

        // Parse the JSON
        const parsed = std.json.parseFromSlice(
            JoinRequest,
            self.allocator,
            body,
            .{},
        ) catch {
            std.debug.print("Failed to parse JSON request\n", .{});
            utils.sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
            return;
        };
        defer parsed.deinit();

        const init_data = parsed.value;

        if (init_data.parts.len <= 1) {
            std.debug.print("Error in joining: Need atleast two files\n", .{});
            utils.sendErrorJson(r, val.UploadError.JoinError, 400);
            return;
        }

        // Create a separate allocator for the video processing
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        std.debug.print("\nJoining videos...\n", .{});
        video.join(allocator, .{
            .output_file = init_data.outputFile,
            .input_files = init_data.parts,
        }) catch |err| {
            std.debug.print("Error in joining: {}\n", .{err});
            utils.sendErrorJson(r, val.UploadError.JoinError, 400);
            return;
        };

        // Send success response
        r.setStatus(.ok);
    } else {
        r.setStatus(.bad_request);
        r.sendBody("Missing request body") catch return;
        return;
    }
}
