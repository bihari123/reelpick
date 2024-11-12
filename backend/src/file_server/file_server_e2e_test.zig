const std = @import("std");
const testing = std.testing;
const http = std.http;
const Thread = std.Thread;

fn runCommand(allocator: std.mem.Allocator, command: []const []const u8) !struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,
} {
    var child = std.process.Child.init(command, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stderr);

    const term = try child.wait();

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .status = switch (term) {
            .Exited => |code| @truncate(code),
            else => 1,
        },
    };
}

const TestServer = struct {
    process: std.process.Child,
    port: u16,
    test_data_dir: []const u8,

    pub fn start(allocator: std.mem.Allocator) !TestServer {
        // Create test data directory if it doesn't exist
        try std.fs.cwd().makePath("test_data");

        // Start the actual server process with working directory set
        var child = std.process.Child.init(
            &.{ "zig", "build", "run", "--", "--port", "3001", "--data-dir", "./test_data" },
            allocator,
        );
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();

        // Give the server time to start
        std.time.sleep(2 * std.time.ns_per_s);

        return TestServer{
            .process = child,
            .port = 5000,
            .test_data_dir = "test_data",
        };
    }

    pub fn stop(self: *TestServer) void {
        _ = self.process.kill() catch |err| {
            std.log.err("error killing the process {!}", .{err});
        };
    }

    // Helper function to create test video files using FFmpeg
    pub fn createTestFiles(self: *TestServer, allocator: std.mem.Allocator) !void {
        // Create test video using FFmpeg
        {
            const test_file_path = try std.fmt.allocPrint(
                allocator,
                "{s}/test_video.mp4",
                .{self.test_data_dir},
            );
            defer allocator.free(test_file_path);

            // Create a 10-second test video
            const command = [_][]const u8{
                "ffmpeg",
                "-f",
                "lavfi",
                "-i",
                "color=c=blue:s=1280x720:d=10",
                "-c:v",
                "libx264",
                test_file_path,
            };

            var child = std.process.Child.init(&command, allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            try child.spawn();
            _ = try child.wait();
        }

        // Create test parts for join operation
        const durations = [_][]const u8{ "5", "5" }; // Two 5-second videos
        const part_files = [_][]const u8{ "part1.mp4", "part2.mp4" };

        for (part_files, 0..) |part_name, i| {
            const part_path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ self.test_data_dir, part_name },
            );
            defer allocator.free(part_path);

            // Create test video parts using different colors
            const color = if (i == 0) "red" else "green";
            const color_config = try std.fmt.allocPrint(
                allocator,
                "color=c={s}:s=1280x720:d={s}",
                .{ color, durations[i] },
            );
            allocator.free(color_config);

            const command = [_][]const u8{
                "ffmpeg",
                "-f",
                "lavfi",
                "-i",
                color_config,
                "-c:v",
                "libx264",
                part_path,
            };

            var child = std.process.Child.init(&command, allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            try child.spawn();
            _ = try child.wait();
        }
    }

    pub fn cleanup(self: *TestServer) void {
        // Clean up test files
        std.fs.cwd().deleteTree(self.test_data_dir) catch |err| {
            std.log.err("error cleaning up test directory: {!}", .{err});
        };
    }
};

test "FileServer E2E - initialization endpoint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.start(allocator);
    defer server.stop();
    defer server.cleanup();

    // Test valid initialization request
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/initialize",
            .{server.port},
        );
        defer allocator.free(endpoint);
        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            "{\"fileName\":\"test.txt\",\"fileSize\":1024,\"totalChunks\":2}",
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.log.info("the result status is {?}", .{result.status});
        try testing.expect(result.status == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "fileId") != null);
    }

    // Test file too large
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/initialize",
            .{server.port},
        );
        defer allocator.free(endpoint);
        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            "{\"fileName\":\"large.txt\",\"fileSize\":2000000000,\"totalChunks\":2000}",
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expect(std.mem.indexOf(u8, result.stdout, "error") != null);
    }

    // Test invalid authorization
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/initialize",
            .{server.port},
        );
        defer allocator.free(endpoint);
        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer invalid_token",
            "-d",
            "{\"fileName\":\"test.txt\",\"fileSize\":1024,\"totalChunks\":2}",
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expect(std.mem.indexOf(u8, result.stdout, "Unauthorized") != null);
    }
}

test "FileServer E2E - upload status endpoint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.start(allocator);
    defer server.stop();
    defer server.cleanup();

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "http://localhost:{d}/api/upload/initialize",
        .{server.port},
    );
    defer allocator.free(endpoint);

    // First create an upload session
    const init_command = [_][]const u8{
        "curl",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Authorization: Bearer tk_1234567890abcdef",
        "-d",
        "{\"fileName\":\"test.txt\",\"fileSize\":1024,\"totalChunks\":2}",
        endpoint,
    };

    const init_result = try runCommand(allocator, &init_command);
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    // Parse the fileId from the response with complete structure
    const InitResponse = struct {
        fileId: []const u8,
        fileName: []const u8,
        fileSize: usize,
        totalChunks: usize,
        chunkSize: usize,
    };

    const response = try std.json.parseFromSlice(
        InitResponse,
        allocator,
        init_result.stdout,
        .{},
    );
    defer response.deinit();

    // Test status check with valid file ID
    {
        const file_id = try std.fmt.allocPrint(
            allocator,
            "x-file-id: {s}",
            .{response.value.fileId},
        );
        defer allocator.free(file_id);

        const endpoint_file_id = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/status",
            .{server.port},
        );
        defer allocator.free(endpoint_file_id);
        const command = [_][]const u8{
            "curl",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-H",
            file_id,
            endpoint_file_id,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expect(std.mem.indexOf(u8, result.stdout, "progress") != null);
    }

    // Test status check with invalid file ID
    {
        const endpoint_invalid_file_id = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/status",
            .{server.port},
        );
        defer allocator.free(endpoint_invalid_file_id);
        const command = [_][]const u8{
            "curl",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-H",
            "x-file-id: invalid_id",
            endpoint_invalid_file_id,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expect(std.mem.indexOf(u8, result.stdout, "error") != null);
    }
}

test "FileServer E2E - video trim endpoint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.start(allocator);
    defer server.stop();
    defer server.cleanup();

    // Create test files
    try server.createTestFiles(allocator);

    // Test valid trim request
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/trim",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"fileName\":\"{s}/test_video.mp4\",\"start_time\":2,\"duration\":5,\"outputFile\":\"{s}/trimmed.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(result.status == 0);
    }

    // Test trim with invalid duration
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/trim",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"fileName\":\"{s}/test_video.mp4\",\"start_time\":0,\"duration\":133330000,\"outputFile\":\"{s}/trimmed_invalid.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // std.testing.log_level = .info;
        // std.log.info("the result is {any} ", .{result.stdout});
        try testing.expect(std.mem.indexOf(u8, result.stdout, "400") != null);
    }

    // Test unauthorized access
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/trim",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"fileName\":\"{s}/test_video.mp4\",\"start_time\":2,\"duration\":5,\"outputFile\":\"{s}/trimmed_unauth.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer invalid_token",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Unauthorized") != null);
    }
}

test "FileServer E2E - video join endpoint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.start(allocator);
    defer server.stop();
    defer server.cleanup();

    // Create test files
    try server.createTestFiles(allocator);

    // Test valid join request
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/join",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"parts\":[\"{s}/part1.mp4\",\"{s}/part2.mp4\"],\"outputFile\":\"{s}/joined.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(result.status == 0);
    }

    // Test join with empty parts array
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/join",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"parts\":[],\"outputFile\":\"{s}/joined_empty.mp4\"}}",
            .{server.test_data_dir},
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.log.debug("result stdout for join with empty part array", .{});
        try testing.expect(std.mem.indexOf(u8, result.stdout, "error") != null);
    }

    // Test unauthorized access
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/join",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"parts\":[\"{s}/part1.mp4\",\"{s}/part2.mp4\"],\"outputFile\":\"{s}/joined_unauth.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer invalid_token",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Unauthorized") != null);
    }

    // Test invalid file paths
    {
        const endpoint = try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/video/join",
            .{server.port},
        );
        defer allocator.free(endpoint);

        const request_body = try std.fmt.allocPrint(
            allocator,
            "{{\"parts\":[\"{s}/nonexistent1.mp4\",\"{s}/nonexistent2.mp4\"],\"outputFile\":\"{s}/joined_invalid.mp4\"}}",
            .{ server.test_data_dir, server.test_data_dir, server.test_data_dir },
        );
        defer allocator.free(request_body);

        const command = [_][]const u8{
            "curl",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-d",
            request_body,
            endpoint,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "error") != null);
    }
}
