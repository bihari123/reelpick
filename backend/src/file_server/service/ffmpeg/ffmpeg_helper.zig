const std = @import("std");
const process = std.process;
const fs = std.fs;
const fmt = std.fmt;
const testing = std.testing;

pub const VideoError = error{
    FFmpegError,
    InvalidArguments,
    MissingInputFile,
    MissingOutputFile,
    InvalidDuration,
    FileCreationError,
    DurationNotFound,
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

fn timeToSeconds(time: []const u8) !u32 {
    // Expected format: HH:MM:SS.ms
    const hours = try std.fmt.parseFloat(f64, time[0..2]);
    const minutes = try std.fmt.parseFloat(f64, time[3..5]);
    const seconds = try std.fmt.parseFloat(f64, time[6..]);

    const total_seconds = (hours * 3600) + (minutes * 60) + seconds;
    return @intFromFloat(@floor(total_seconds));
}

pub fn getVideoDuration(allocator: std.mem.Allocator, filename: []const u8) !u32 {
    var child = std.process.Child.init(&[_][]const u8{
        "ffmpeg",
        "-i",
        filename,
    }, allocator);

    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stderr);

    _ = try child.wait();

    if (std.mem.indexOf(u8, stderr, "Duration: ")) |start| {
        const duration_str = stderr[start + 10 .. start + 21];
        return try timeToSeconds(duration_str);
    }

    return VideoError.DurationNotFound;
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

// Tests
test "Duration.fromSeconds correctly converts seconds to Duration" {
    const test_cases = [_]struct {
        input: u32,
        expected: Duration,
    }{
        .{ .input = 0, .expected = Duration{ .hours = 0, .minutes = 0, .seconds = 0 } },
        .{ .input = 45, .expected = Duration{ .hours = 0, .minutes = 0, .seconds = 45 } },
        .{ .input = 60, .expected = Duration{ .hours = 0, .minutes = 1, .seconds = 0 } },
        .{ .input = 3661, .expected = Duration{ .hours = 1, .minutes = 1, .seconds = 1 } },
        .{ .input = 7323, .expected = Duration{ .hours = 2, .minutes = 2, .seconds = 3 } },
    };

    for (test_cases) |tc| {
        const result = Duration.fromSeconds(tc.input);
        try testing.expectEqual(tc.expected.hours, result.hours);
        try testing.expectEqual(tc.expected.minutes, result.minutes);
        try testing.expectEqual(tc.expected.seconds, result.seconds);
    }
}

test "Duration.format produces correct time string" {
    const test_cases = [_]struct {
        input: Duration,
        expected: []const u8,
    }{
        .{ .input = Duration{ .hours = 0, .minutes = 0, .seconds = 0 }, .expected = "00:00:00" },
        .{ .input = Duration{ .hours = 1, .minutes = 2, .seconds = 3 }, .expected = "01:02:03" },
        .{ .input = Duration{ .hours = 23, .minutes = 59, .seconds = 59 }, .expected = "23:59:59" },
    };

    for (test_cases) |tc| {
        const result = try tc.input.format();
        try testing.expectEqualStrings(tc.expected, result[0..8]);
    }
}
test "trim function validates input parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_options = TrimOptions{
        .input_file = "",
        .output_file = "",
        .start = Duration{},
        .duration = Duration{},
    };

    // Test with empty input file
    const trim_result = trim(allocator, invalid_options);
    try testing.expectError(VideoError.FFmpegError, trim_result);
}
test "join function validates minimum input files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with single input file (should require at least 2)
    const invalid_options = JoinOptions{
        .output_file = "output.mp4",
        .input_files = &[_][]const u8{"single_file.mp4"},
    };

    const join_result = join(allocator, invalid_options);
    try testing.expectError(VideoError.InvalidArguments, join_result);
}
test "join function handles valid input parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create temporary test files
    const test_files = [_][]const u8{ "test1.mp4", "test2.mp4" };
    for (test_files) |file| {
        const f = std.fs.cwd().createFile(file, .{}) catch |err| {
            std.debug.print("Failed to create test file: {}\n", .{err});
            continue;
        };
        f.close();
    }
    defer {
        for (test_files) |file| {
            std.fs.cwd().deleteFile(file) catch {};
        }
    }

    const valid_options = JoinOptions{
        .output_file = "joined_output.mp4",
        .input_files = &test_files,
    };

    // This will fail because the test files are empty, but it tests the parameter validation
    const join_result = join(allocator, valid_options);
    try testing.expectError(VideoError.FFmpegError, join_result);
}
