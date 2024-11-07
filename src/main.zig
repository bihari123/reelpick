const std = @import("std");

const opensearch = @import("./layer/service/opensearch/opensearch_helper.zig");
pub fn main() !void {
    // Initialize memory allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client with custom options
    const options = opensearch.ClientOptions{
        .connect_timeout_ms = 5000,
        .request_timeout_ms = 10000,
        .max_retries = 3,
        .retry_delay_ms = 1000,
    };

    var client = try opensearch.OpenSearchClient.init(allocator, "http://localhost:9200", options);
    defer client.deinit();

    // First create an index with settings
    const settings =
        \\{
        \\  "settings": {
        \\    "index": {
        \\      "number_of_shards": 1,
        \\      "number_of_replicas": 1
        \\    }
        \\  },
        \\  "mappings": {
        \\    "properties": {
        \\      "title": { "type": "text" },
        \\      "content": { "type": "text" },
        \\      "timestamp": { "type": "date" }
        \\    }
        \\  }
        \\}
    ;

    // Create the test index
    std.log.info("Creating index...", .{});
    try client.createIndex("test_index", settings);

    // Create multiple threads
    var threads: [3]std.Thread = undefined;
    const contexts = [_]opensearch.ThreadContext{
        .{ .client = client, .index_name = "test_index", .doc_id = "1", .document = 
        \\{
        \\  "title": "Document 1",
        \\  "content": "This is the content of document 1",
        \\  "timestamp": "2024-03-06T12:00:00Z"
        \\}
        },
        .{ .client = client, .index_name = "test_index", .doc_id = "2", .document = 
        \\{
        \\  "title": "Document 2",
        \\  "content": "This is the content of document 2",
        \\  "timestamp": "2024-03-06T12:01:00Z"
        \\}
        },
        .{ .client = client, .index_name = "test_index", .doc_id = "3", .document = 
        \\{
        \\  "title": "Document 3",
        \\  "content": "This is the content of document 3",
        \\  "timestamp": "2024-03-06T12:02:00Z"
        \\}
        },
    };

    std.log.info("Starting concurrent indexing...", .{});

    // Start threads
    for (contexts, 0..) |ctx, i| {
        threads[i] = try std.Thread.spawn(.{}, opensearch.indexWorker, .{ctx});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    std.log.info("Concurrent indexing completed", .{});

    // Wait a moment for indexing to complete
    std.time.sleep(1 * std.time.ns_per_s);

    // Test various search queries
    const search_tests = [_]struct {
        name: []const u8,
        query: []const u8,
    }{
        .{ .name = "Match all", .query = 
        \\{
        \\  "query": {
        \\    "match_all": {}
        \\  }
        \\}
        },
        .{ .name = "Term search", .query = 
        \\{
        \\  "query": {
        \\    "match": {
        \\      "content": "document"
        \\    }
        \\  }
        \\}
        },
        .{ .name = "Range query", .query = 
        \\{
        \\  "query": {
        \\    "range": {
        \\      "timestamp": {
        \\        "gte": "2024-03-06T12:00:00Z",
        \\        "lte": "2024-03-06T12:02:00Z"
        \\      }
        \\    }
        \\  }
        \\}
        },
    };

    // Perform search tests
    std.log.info("Starting search tests...", .{});
    for (search_tests) |this_test| {
        std.log.info("Executing {s} search...", .{this_test.name});
        const response = try client.search("test_index", this_test.query);
        defer allocator.free(response);
        std.log.info("{s} response: {s}", .{ this_test.name, response });
    }

    // Test bulk indexing
    std.log.info("Testing bulk indexing...", .{});
    const bulk_data =
        \\{"index":{"_index":"test_index","_id":"bulk1"}}
        \\{"title":"Bulk Document 1","content":"Bulk test content 1","timestamp":"2024-03-06T12:03:00Z"}
        \\{"index":{"_index":"test_index","_id":"bulk2"}}
        \\{"title":"Bulk Document 2","content":"Bulk test content 2","timestamp":"2024-03-06T12:04:00Z"}
        \\
    ;

    const bulk_response = try client.bulk(bulk_data);
    defer allocator.free(bulk_response);
    std.log.info("Bulk indexing response: {s}", .{bulk_response});

    // Wait a moment before cleanup
    std.time.sleep(1 * std.time.ns_per_s);

    // Cleanup
    std.log.info("Cleaning up test index...", .{});
    try client.deleteIndex("test_index");

    std.log.info("Test completed successfully", .{});
}
