const std = @import("std");
const process = std.process;
const fs = std.fs;
const fmt = std.fmt;

pub const VideoError = error{
    FFmpegError,
    InvalidArguments,
    MissingInputFile,
    MissingOutputFile,
    InvalidDuration,
    FileCreationError,
};

pub const Duration = struct {
    hours: u32 = 0,
    minutes: u32 = 0,
    seconds: u32 = 0,

    pub fn format(self: Duration) ![64]u8 {
        var buffer: [64]u8 = undefined;
        const result = try fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hours, self.minutes, self.seconds });
        var final_buffer: [64]u8 = undefined;
        @memcpy(final_buffer[0..result.len], result);
        return final_buffer;
    }

    pub fn fromSeconds(total_seconds: u32) Duration {
        const hours = total_seconds / 3600;
        const minutes = (total_seconds % 3600) / 60;
        const seconds = total_seconds % 60;
        return Duration{ .hours = hours, .minutes = minutes, .seconds = seconds };
    }
};

pub const TrimOptions = struct {
    input_file: []const u8,
    start: Duration,
    duration: Duration,
    output_file: []const u8,
};

pub const JoinOptions = struct {
    output_file: []const u8,
    input_files: []const []const u8,
};

/// Trims a video file using FFmpeg
pub fn trim(allocator: std.mem.Allocator, options: TrimOptions) !void {
    const start_time = try options.start.format();
    const duration_time = try options.duration.format();

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "ffmpeg",
            "-i",
            options.input_file,
            "-ss",
            start_time[0..8],
            "-t",
            duration_time[0..8],
            "-c",
            "copy",
            options.output_file,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        std.debug.print("Video trimmed successfully!\n", .{});
        std.debug.print("Output file: {s}\n", .{options.output_file});
    } else {
        std.debug.print("FFmpeg failed with error code: {}\n", .{result.term.Exited});
        if (result.stderr.len > 0) {
            std.debug.print("Error output: {s}\n", .{result.stderr});
        }
        return VideoError.FFmpegError;
    }
}

/// Joins multiple video files using FFmpeg's concat demuxer
pub fn join(allocator: std.mem.Allocator, options: JoinOptions) !void {
    if (options.input_files.len < 2) {
        return VideoError.InvalidArguments;
    }

    // Create a temporary file list
    const list_file = "temp_file_list.txt";
    const file = try fs.cwd().createFile(list_file, .{});
    defer {
        file.close();
        fs.cwd().deleteFile(list_file) catch {};
    }

    // Write file paths to the list file
    var writer = file.writer();
    for (options.input_files) |input_file| {
        try writer.print("file '{s}'\n", .{input_file});
    }

    // Run FFmpeg to concatenate the files
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "ffmpeg",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            list_file,
            "-c",
            "copy",
            options.output_file,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        std.debug.print("Videos joined successfully!\n", .{});
        std.debug.print("Output file: {s}\n", .{options.output_file});
    } else {
        std.debug.print("FFmpeg failed with error code: {}\n", .{result.term.Exited});
        if (result.stderr.len > 0) {
            std.debug.print("Error output: {s}\n", .{result.stderr});
        }
        return VideoError.FFmpegError;
    }
}
