const std = @import("std");
const process = std.process;
const fmt = std.fmt;
const mem = std.mem;
const fs = std.fs;

const VideoCommand = enum {
    trim,
    join,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Get command type
    const command_str = args.next() orelse {
        printUsage();
        return error.InvalidArguments;
    };

    const command = std.meta.stringToEnum(VideoCommand, command_str) orelse {
        std.debug.print("Invalid command: {s}\n", .{command_str});
        printUsage();
        return error.InvalidArguments;
    };

    switch (command) {
        .trim => try handleTrim(&args, allocator),
        .join => try handleJoin(&args, allocator),
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: 
        \\  Trim: video-tools trim <input_file> <start_time> <duration> <output_file>
        \\  Example: video-tools trim input.mp4 00:00:30 00:00:10 output.mp4
        \\
        \\  Join: video-tools join <output_file> <input_file1> <input_file2> [input_file3...]
        \\  Example: video-tools join output.mp4 part1.mp4 part2.mp4 part3.mp4
        \\
    , .{});
}

fn handleTrim(args: *process.ArgIterator, allocator: std.mem.Allocator) !void {
    const input_file = args.next() orelse {
        std.debug.print("Error: Input file required\n", .{});
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

fn handleJoin(args: *process.ArgIterator, allocator: std.mem.Allocator) !void {
    const output_file = args.next() orelse {
        std.debug.print("Error: Output file required\n", .{});
        return error.InvalidArguments;
    };

    // Collect input files
    var input_files = std.ArrayList([]const u8).init(allocator);
    defer input_files.deinit();

    while (args.next()) |file| {
        try input_files.append(file);
    }

    if (input_files.items.len < 2) {
        std.debug.print("Error: At least two input files are required for joining\n", .{});
        return error.InvalidArguments;
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
    for (input_files.items) |input_file| {
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
            output_file,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        std.debug.print("Videos joined successfully!\n", .{});
    } else {
        std.debug.print("FFmpeg failed with error code: {}\n", .{result.term.Exited});
        if (result.stderr.len > 0) {
            std.debug.print("Error output: {s}\n", .{result.stderr});
        }
        return error.FFmpegError;
    }
}
