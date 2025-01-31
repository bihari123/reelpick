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

const MAX_DURATION_SECONDS: u32 = 3600; // 1 hour in seconds

pub fn handleTrim(ep: *zap.Endpoint, r: zap.Request) void {
    std.debug.print("insied trim", .{});
    const self: *server.FileServer = @fieldParentPtr("ep_trim", ep);
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

    if (r.body) |body| {
        const parsed = std.json.parseFromSlice(struct {
            fileName: []u8,
            start_time: u32, // start_time in secs
            duration: u32, // duration in sec
            outputFile: []u8,
        }, self.allocator, body, .{}) catch {
            utils.sendErrorJson(r, val.UploadError.InvalidRequestBody, 400);
            return;
        };
        defer parsed.deinit();

        const init_data = parsed.value;

        // Validate duration
        if (init_data.duration == 0) {
            utils.sendErrorJson(r, val.UploadError.InvalidDuration, 400);
            return;
        }

        if (init_data.duration > MAX_DURATION_SECONDS) {
            utils.sendErrorJson(r, val.UploadError.DurationTooLong, 400);
            return;
        }

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Get video duration first
        const video_duration = video.getVideoDuration(allocator, init_data.fileName) catch {
            utils.sendErrorJson(r, val.UploadError.VideoInfoError, 400);
            return;
        };
        // defer video_duration.deinit();

        // Check if start_time + duration exceeds video length
        if (init_data.start_time + init_data.duration > video_duration) {
            utils.sendErrorJson(r, val.UploadError.InvalidTrimRange, 400);
            return;
        }

        video.trim(allocator, .{
            .input_file = init_data.fileName,
            .start = video.Duration.fromSeconds(init_data.start_time),
            .duration = video.Duration.fromSeconds(init_data.duration),
            .output_file = init_data.outputFile,
        }) catch {
            std.debug.print("error in trimming", .{});
            utils.sendErrorJson(r, val.UploadError.TrimError, 500);
            return;
        };
    } else {
        r.setStatus(.bad_request);
        r.sendBody("Invalid request body") catch return;
        return;
    }
}
