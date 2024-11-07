const std = @import("std");
const process = std.process;
const fmt = std.fmt;
const mem = std.mem;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Parse arguments
    const input_file = args.next() orelse {
        std.debug.print("Usage: {s} <input_file> <start_time> <duration> <output_file>\n", .{"video-trimmer"});
        std.debug.print("Example: {s} input.mp4 00:00:30 00:00:10 output.mp4\n", .{"video-trimmer"});
        return error.InvalidArguments;
    };

    const start_time = args.next() orelse {
        std.debug.print("Error: Start time required\n", .{});
        return error.InvalidArguments;
    };

    const duration = args.next() orelse {
        std.debug.print("Error: Duration required\n", .{});
        return error.InvalidArguments;
    };

    const output_file = args.next() orelse {
        std.debug.print("Error: Output file required\n", .{});
        return error.InvalidArguments;
    };

    // Create child process
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "ffmpeg",
            "-i",
            input_file,
            "-ss",
            start_time,
            "-t",
            duration,
            "-c",
            "copy",
            output_file,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        std.debug.print("Video trimmed successfully!\n", .{});
    } else {
        std.debug.print("FFmpeg failed with error code: {}\n", .{result.term.Exited});
        if (result.stderr.len > 0) {
            std.debug.print("Error output: {s}\n", .{result.stderr});
        }
        return error.FFmpegError;
    }
}
