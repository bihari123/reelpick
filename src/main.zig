const std = @import("std");

const redis = @import("./layer/service/redis/redis_helper.zig");

pub fn main() !void {
    std.debug.print("Starting Redis Job Queue System...\n", .{});

    // First check if Redis is running
    redis.checkRedisConnection() catch |err| {
        std.debug.print("\nRedis connection check failed: {}\n", .{err});
        std.debug.print("\nPlease ensure that:\n", .{});
        std.debug.print("1. Redis server is running (run: redis-server)\n", .{});
        std.debug.print("2. Redis is accessible on localhost:6379\n", .{});
        std.debug.print("3. You have proper permissions\n", .{});
        return err;
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\nInitializing job queue...\n", .{});
    const queue = try redis.RedisJobQueue.init(allocator, "localhost", 6379, 3);
    defer queue.deinit();

    // Example job with proper memory management
    const example_job = try redis.Job.init(allocator, "test_job_001", "example data payload");
    defer example_job.deinit();

    try queue.pushJob(example_job);

    std.debug.print("\nJob pushed successfully, starting worker...\n", .{});

    // Process jobs in a worker thread
    const Worker = struct {
        queue: *redis.RedisJobQueue,
        allocator: std.mem.Allocator,

        fn run(self: @This()) !void {
            var job_count: usize = 0;
            std.debug.print("\nWorker started, waiting for jobs...\n", .{});

            while (true) {
                if (try self.queue.getNextJob()) |job| {
                    defer job.deinit();
                    job_count += 1;

                    std.debug.print("\nProcessing job {d}: {s}\n", .{ job_count, job.id });
                    std.debug.print("Job data: {s}\n", .{job.data});

                    // Simulate some work
                    std.time.sleep(2 * std.time.ns_per_s);

                    try self.queue.updateJobStatus(job.id, .completed);
                    std.debug.print("Job {s} completed successfully\n", .{job.id});
                }
                std.time.sleep(std.time.ns_per_s);
            }
        }
    };

    const worker = Worker{
        .queue = queue,
        .allocator = allocator,
    };

    std.debug.print("\nSpawning worker thread...\n", .{});
    const thread = try std.Thread.spawn(.{}, Worker.run, .{worker});

    std.debug.print("\nMain thread waiting for worker to complete...\n", .{});
    thread.join();
}
