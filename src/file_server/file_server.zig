const std = @import("std");
const zap = @import("zap");
const redis = @import("../service/redis/redis_helper.zig");
const sqlite = @import("../service/sqlite/sqlite_helper.zig");
const Thread = std.Thread;
const val = @import("./layer/controller/utils.zig");
const repo = @import("./layer/repo/db.zig");
const initialize = @import("./layer/controller/initialize.zig");
const upload = @import("./layer/controller/upload.zig");
const status = @import("./layer/controller/status.zig");

pub const FileServer = struct {
    allocator: std.mem.Allocator,
    redis_client: redis.RedisClient,
    ep_initialize: zap.Endpoint,
    ep_chunk: zap.Endpoint,
    ep_status: zap.Endpoint,

    pub fn init(allocator: std.mem.Allocator) !*FileServer {
        // Create uploads directory
        try std.fs.cwd().makePath(val.UPLOAD_DIR);

        // Initialize Redis client
        const redis_client = try redis.RedisClient.init(allocator, "localhost", 6379);

        // Create server instance
        const server = try allocator.create(FileServer);
        errdefer allocator.destroy(server);

        server.* = .{
            .allocator = allocator,
            .redis_client = redis_client,
            .ep_initialize = zap.Endpoint.init(.{
                .path = "/api/upload/initialize",
                .post = initialize.handleInitialize,
                .options = status.handleOptions,
            }),
            .ep_chunk = zap.Endpoint.init(.{
                .path = "/api/upload/chunk",
                .post = upload.handleChunk,
                .options = status.handleOptions,
            }),
            .ep_status = zap.Endpoint.init(.{
                .path = "/api/upload/status",
                .get = status.handleStatus,
                .options = status.handleOptions,
            }),
        };

        return server;
    }

    pub fn deinit(self: *FileServer) void {
        self.redis_client.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *FileServer, port: u16) !void {
        var listener = zap.Endpoint.Listener.init(self.allocator, .{
            .port = port,
            .on_request = null,
            .log = true,
            .max_body_size = val.MAX_FILE_SIZE,
        });
        defer listener.deinit();

        // Register endpoints
        try listener.register(&self.ep_initialize);
        try listener.register(&self.ep_chunk);
        try listener.register(&self.ep_status);

        try listener.listen();

        std.debug.print("Server listening on port {d}\n", .{port});

        // Start the event loop
        zap.start(.{
            .threads = 4,
            .workers = 1,
        });
    }
};