const std = @import("std");
const c = @cImport({
    @cInclude("hiredis/hiredis.h");
});

pub const JobStatus = enum {
    pending,
    processing,
    completed,
    failed,
};

pub const JobError = error{
    ConnectionFailed,
    CommandFailed,
    InvalidJobData,
    JobNotFound,
    QueueFull,
    RedisError,
};

pub const Job = struct {
    id: []const u8,
    data: []const u8,
    status: JobStatus,
    created_at: i64,
    updated_at: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, data: []const u8) !*Job {
        const job = try allocator.create(Job);
        job.* = .{
            .id = try allocator.dupe(u8, id),
            .data = try allocator.dupe(u8, data),
            .status = .pending,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .allocator = allocator,
        };
        return job;
    }

    pub fn deinit(self: *Job) void {
        self.allocator.free(self.id);
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};

pub const RedisJobQueue = struct {
    context: ?*c.redisContext,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_retries: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, max_retries: u32) !*Self {
        std.debug.print("Initializing Redis Job Queue...\n", .{});

        const self = try allocator.create(Self);
        self.* = .{
            .context = null,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .max_retries = max_retries,
        };

        try self.connect(host, port);
        std.debug.print("Redis Job Queue initialized successfully\n", .{});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.context) |ctx| {
            c.redisFree(ctx);
        }
        self.allocator.destroy(self);
    }

    fn connect(self: *Self, host: []const u8, port: u16) !void {
        std.debug.print("Connecting to Redis at {s}:{d}...\n", .{ host, port });

        var retry_count: u32 = 0;
        while (retry_count < self.max_retries) : (retry_count += 1) {
            if (retry_count > 0) {
                std.debug.print("Retrying connection (attempt {d}/{d})...\n", .{ retry_count + 1, self.max_retries });
            }

            var host_buf: [256]u8 = undefined;
            const host_z = try std.fmt.bufPrintZ(&host_buf, "{s}", .{host});

            const ctx = c.redisConnect(host_z.ptr, port);
            if (ctx == null) {
                std.debug.print("Failed to allocate Redis context\n", .{});
                std.time.sleep(std.time.ns_per_s);
                continue;
            }

            if (ctx.*.err != 0) {
                const err_str = if (ctx.*.errstr[0] != 0) ctx.*.errstr[0 .. std.mem.indexOfScalar(u8, &ctx.*.errstr, 0) orelse 0] else "Unknown error";
                std.debug.print("Connection error: {s}\n", .{err_str});
                c.redisFree(ctx);
                std.time.sleep(std.time.ns_per_s);
                continue;
            }

            self.context = ctx;
            return;
        }

        std.debug.print("Failed to connect after {d} attempts\n", .{self.max_retries});
        return JobError.ConnectionFailed;
    }

    fn redisCmd(ctx: *c.redisContext, cmd: [*:0]const u8) !?*c.redisReply {
        std.debug.print("Executing Redis command: {s}\n", .{cmd});

        const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, cmd))));
        if (reply) |r| {
            if (r.type == c.REDIS_REPLY_ERROR) {
                const err_str = r.str[0..@intCast(r.len)];
                std.debug.print("Redis error: {s}\n", .{err_str});
                c.freeReplyObject(r);
                return JobError.CommandFailed;
            }
            return r;
        }

        if (ctx.*.err != 0) {
            const err_str = if (ctx.*.errstr[0] != 0) ctx.*.errstr[0 .. std.mem.indexOfScalar(u8, &ctx.*.errstr, 0) orelse 0] else "Unknown error";
            std.debug.print("Redis context error: {s}\n", .{err_str});
        }
        return JobError.CommandFailed;
    }

    pub fn pushJob(self: *Self, job: *Job) !void {
        std.debug.print("Pushing new job: {s}\n", .{job.id});

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.context) |ctx| {
            var cmd_buf: [512]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "HMSET job:{s} id {s} data {s} status {s} created_at {} updated_at {}", .{
                job.id,
                job.id,
                job.data,
                @tagName(job.status),
                job.created_at,
                job.updated_at,
            });

            const reply = try redisCmd(ctx, cmd.ptr);
            if (reply) |r| {
                defer c.freeReplyObject(r);

                var queue_cmd_buf: [256]u8 = undefined;
                const queue_cmd = try std.fmt.bufPrintZ(&queue_cmd_buf, "LPUSH pending_jobs job:{s}", .{job.id});

                const queue_reply = try redisCmd(ctx, queue_cmd.ptr);
                if (queue_reply) |qr| {
                    defer c.freeReplyObject(qr);
                    std.debug.print("Job {s} pushed successfully\n", .{job.id});
                }
            }
        } else {
            std.debug.print("Redis context is null\n", .{});
            return JobError.ConnectionFailed;
        }
    }

    pub fn getNextJob(self: *Self) !?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.context) |ctx| {
            const reply = try redisCmd(ctx, "RPOPLPUSH pending_jobs processing_jobs");

            if (reply) |r| {
                defer c.freeReplyObject(r);

                if (r.type == c.REDIS_REPLY_STRING) {
                    const job_key = r.str[0..@intCast(r.len)];
                    return try self.getJobData(job_key);
                }
            }
        }
        return null;
    }

    fn getJobData(self: *Self, job_key: []const u8) !*Job {
        std.debug.print("Getting job data for key: {s}\n", .{job_key});

        if (self.context) |ctx| {
            var cmd_buf: [256]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "HGETALL {s}", .{job_key});

            const reply = try redisCmd(ctx, cmd.ptr);
            if (reply) |r| {
                defer c.freeReplyObject(r);

                if (r.type == c.REDIS_REPLY_ARRAY) {
                    var job_data = std.StringHashMap([]const u8).init(self.allocator);
                    defer job_data.deinit();

                    var i: usize = 0;
                    const elements = @as([*]*c.redisReply, @ptrCast(@alignCast(r.element)));
                    while (i < r.elements) : (i += 2) {
                        const key = elements[i].str[0..@intCast(elements[i].len)];
                        const value = elements[i + 1].str[0..@intCast(elements[i + 1].len)];
                        try job_data.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
                    }

                    const id = job_data.get("id") orelse return JobError.InvalidJobData;
                    const data = job_data.get("data") orelse return JobError.InvalidJobData;
                    const status_str = job_data.get("status") orelse return JobError.InvalidJobData;
                    const created_at_str = job_data.get("created_at") orelse return JobError.InvalidJobData;
                    const updated_at_str = job_data.get("updated_at") orelse return JobError.InvalidJobData;

                    const job = try self.allocator.create(Job);
                    job.* = .{
                        .id = try self.allocator.dupe(u8, id),
                        .data = try self.allocator.dupe(u8, data),
                        .status = std.meta.stringToEnum(JobStatus, status_str) orelse .pending,
                        .created_at = try std.fmt.parseInt(i64, created_at_str, 10),
                        .updated_at = try std.fmt.parseInt(i64, updated_at_str, 10),
                        .allocator = self.allocator,
                    };

                    std.debug.print("Successfully retrieved job data for {s}\n", .{job.id});
                    return job;
                }
            }
        }
        std.debug.print("Failed to get job data\n", .{});
        return JobError.JobNotFound;
    }

    pub fn updateJobStatus(self: *Self, job_id: []const u8, new_status: JobStatus) !void {
        std.debug.print("Updating status for job {s} to {s}\n", .{ job_id, @tagName(new_status) });

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.context) |ctx| {
            const now = std.time.timestamp();

            var job_key_buf: [256]u8 = undefined;
            const job_key = try std.fmt.bufPrintZ(&job_key_buf, "job:{s}", .{job_id});

            var cmd_buf: [256]u8 = undefined;
            const cmd = try std.fmt.bufPrintZ(&cmd_buf, "HMSET {s} status {s} updated_at {}", .{
                job_key,
                @tagName(new_status),
                now,
            });

            const reply = try redisCmd(ctx, cmd.ptr);
            if (reply) |r| {
                defer c.freeReplyObject(r);

                switch (new_status) {
                    .completed => {
                        var remove_cmd_buf: [256]u8 = undefined;
                        var add_cmd_buf: [256]u8 = undefined;

                        const remove_cmd = try std.fmt.bufPrintZ(&remove_cmd_buf, "LREM processing_jobs 0 {s}", .{job_key});
                        const add_cmd = try std.fmt.bufPrintZ(&add_cmd_buf, "LPUSH completed_jobs {s}", .{job_key});

                        _ = try redisCmd(ctx, remove_cmd.ptr);
                        _ = try redisCmd(ctx, add_cmd.ptr);
                        std.debug.print("Job {s} marked as completed\n", .{job_id});
                    },
                    .failed => {
                        var remove_cmd_buf: [256]u8 = undefined;
                        var add_cmd_buf: [256]u8 = undefined;

                        const remove_cmd = try std.fmt.bufPrintZ(&remove_cmd_buf, "LREM processing_jobs 0 {s}", .{job_key});
                        const add_cmd = try std.fmt.bufPrintZ(&add_cmd_buf, "LPUSH failed_jobs {s}", .{job_key});

                        _ = try redisCmd(ctx, remove_cmd.ptr);
                        _ = try redisCmd(ctx, add_cmd.ptr);
                        std.debug.print("Job {s} marked as failed\n", .{job_id});
                    },
                    else => {},
                }
            }
        } else {
            std.debug.print("Redis context is null\n", .{});
            return JobError.ConnectionFailed;
        }
    }
};

pub fn checkRedisConnection() !void {
    std.debug.print("Performing initial Redis connection check...\n", .{});

    var host_buf: [256]u8 = undefined;
    const host_z = try std.fmt.bufPrintZ(&host_buf, "localhost", .{});

    const ctx = c.redisConnect(host_z.ptr, 6379);
    if (ctx == null) {
        std.debug.print("Cannot allocate redis context\n", .{});
        return error.ConnectionFailed;
    }
    defer c.redisFree(ctx);

    if (ctx.*.err != 0) {
        const err_str = if (ctx.*.errstr[0] != 0) ctx.*.errstr[0 .. std.mem.indexOfScalar(u8, &ctx.*.errstr, 0) orelse 0] else "Unknown error";
        std.debug.print("Connection error: {s}\n", .{err_str});
        return error.ConnectionFailed;
    }

    const reply = @as(?*c.redisReply, @ptrCast(@alignCast(c.redisCommand(ctx, "PING"))));
    if (reply) |r| {
        defer c.freeReplyObject(r);
        if (r.type == c.REDIS_REPLY_ERROR) {
            std.debug.print("Redis PING failed\n", .{});
            return error.ConnectionFailed;
        }
        std.debug.print("Redis is running and responding to PING\n", .{});
    } else {
        std.debug.print("Redis PING command failed\n", .{});
        return error.ConnectionFailed;
    }
}
