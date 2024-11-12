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

    pub fn start(allocator: std.mem.Allocator) !TestServer {
        // Start the actual server process
        var child = std.process.Child.init(&.{ "zig", "build", "run", "--", "--port", "3001" }, allocator);
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();

        // Give the server time to start
        std.time.sleep(2 * std.time.ns_per_s);

        return TestServer{
            .process = child,
            .port = 5000,
        };
    }

    pub fn stop(self: *TestServer) void {
        _ = self.process.kill() catch |err| {
            std.log.err("error killing the process {!}", .{err});
        };
    }
};

test "FileServer E2E - initialization endpoint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.start(allocator);
    defer server.stop();

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
    const endpoint =try std.fmt.allocPrint(
        allocator,
        "http://localhost:{d}/api/upload/initialize",
        .{server.port},
    ) ;
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
        const file_id =try std.fmt.allocPrint(
            allocator,
            "x-file-id: {s}",
            .{response.value.fileId},
        ) ;
        defer allocator.free(file_id);

        const endpoint_file_id =try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/status",
            .{server.port},
        )  ;
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
        const endpoint_invalide_file_id =try std.fmt.allocPrint(
            allocator,
            "http://localhost:{d}/api/upload/status",
            .{server.port},
        )  ;
        defer allocator.free(endpoint_invalide_file_id);
        const command = [_][]const u8{
            "curl",
            "-H",
            "Authorization: Bearer tk_1234567890abcdef",
            "-H",
            "x-file-id: invalid_id",
            endpoint_invalide_file_id,
        };

        const result = try runCommand(allocator, &command);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try testing.expect(std.mem.indexOf(u8, result.stdout, "error") != null);
    }
}

