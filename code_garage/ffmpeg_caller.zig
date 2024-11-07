// src/main.zig
const std = @import("std");
const video = @import("./layer/service/ffmpeg/ffmpeg_helper.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example paths - replace these with your actual paths
    const paths = .{
        .input = "../../sample/sample1.mp4",
        .output = "output.mp4",
        .parts = &[_][]const u8{
            "../../sample/sample1.mp4",
            "../../sample/sample2.mp4",
        },
    };

    // Example 1: Trim video using Duration struct
    std.debug.print("\nTrimming video...\n", .{});
    try video.trim(allocator, .{
        .input_file = paths.input,
        .start = .{ .minutes = 1, .seconds = 30 }, // start at 1:30
        .duration = .{ .minutes = 2, .seconds = 15 }, // trim for 2:15
        .output_file = "trimmed_" ++ paths.output,
    });

    // Alternative: Using fromSeconds
    try video.trim(allocator, .{
        .input_file = paths.input,
        .start = video.Duration.fromSeconds(90), // start at 1:30
        .duration = video.Duration.fromSeconds(135), // trim for 2:15
        .output_file = "trimmed2_" ++ paths.output,
    });

    // Example 2: Join videos
    std.debug.print("\nJoining videos...\n", .{});
    try video.join(allocator, .{
        .output_file = "joined_" ++ paths.output,
        .input_files = paths.parts,
    });
}
