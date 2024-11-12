const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});
const log = std.log;

pub const OpenSearchError = error{
    InitError,
    RequestError,
    JsonError,
    InvalidResponse,
    OutOfMemory,
    URLError,
};

pub const OpenSearchClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    base_url: []const u8,
    mutex: std.Thread.Mutex,
    curl: *c.CURL,

    var instance: ?*Self = null;
    var instance_mutex: std.Thread.Mutex = .{};

    const Response = struct {
        data: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) Response {
            return .{
                .data = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *Response) void {
            self.data.deinit();
        }
    };

    pub fn getInstance(allocator: std.mem.Allocator, base_url: []const u8) !*Self {
        instance_mutex.lock();
        defer instance_mutex.unlock();

        if (instance == null) {
            var client = try allocator.create(Self);
            errdefer allocator.destroy(client);
            try client.init(allocator, base_url);
            instance = client;
        }

        return instance.?;
    }

    fn init(self: *Self, allocator: std.mem.Allocator, base_url: []const u8) !void {
        const curl = c.curl_easy_init() orelse return OpenSearchError.InitError;
        errdefer c.curl_easy_cleanup(curl);

        const url_copy = try allocator.dupe(u8, base_url);
        errdefer allocator.free(url_copy);

        self.* = .{
            .allocator = allocator,
            .base_url = url_copy,
            .mutex = .{},
            .curl = curl,
        };

        // Set common CURL options
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
            return OpenSearchError.InitError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
            return OpenSearchError.InitError;
        }
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.base_url);
        c.curl_easy_cleanup(self.curl);
        self.allocator.destroy(self);
        instance = null;
    }

    fn writeCallback(data: [*c]u8, size: c_uint, nmemb: c_uint, user_data: *Response) callconv(.C) c_uint {
        const real_size = size * nmemb;
        const slice = data[0..real_size];
        user_data.data.appendSlice(slice) catch return 0;
        return @intCast(real_size);
    }

    pub fn search(self: *Self, this_index: []const u8, query: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var response = Response.init(self.allocator);
        defer response.deinit();

        // Ensure query and this_index are null-terminated
        const index_nt = try std.fmt.allocPrintZ(self.allocator, "{s}", .{this_index});
        defer self.allocator.free(index_nt);

        const url = try std.fmt.allocPrintZ(self.allocator, "{s}/{s}/_search", .{ self.base_url, index_nt });
        defer self.allocator.free(url);

        const query_nt = try std.fmt.allocPrintZ(self.allocator, "{s}", .{query});
        defer self.allocator.free(query_nt);

        // Reset CURL handle to default state
        c.curl_easy_reset(self.curl);

        // Set request specific options
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_URL, url.ptr) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_POSTFIELDS, query_nt.ptr) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEDATA, &response) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        // Add headers
        var headers: ?*c.curl_slist = null;
        headers = c.curl_slist_append(headers, "Content-Type: application/json");
        defer if (headers) |h| c.curl_slist_free_all(h);

        if (c.curl_easy_setopt(self.curl, c.CURLOPT_HTTPHEADER, headers) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        // Perform request
        const res = c.curl_easy_perform(self.curl);
        if (res != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        var response_code: c_long = undefined;
        _ = c.curl_easy_getinfo(self.curl, c.CURLINFO_RESPONSE_CODE, &response_code);
        if (response_code < 200 or response_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }

        return response.data.toOwnedSlice();
    }

    pub fn index(self: *Self, index_name: []const u8, doc_id: []const u8, document: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var response = Response.init(self.allocator);
        defer response.deinit();

        // Ensure strings are null-terminated
        const index_nt = try std.fmt.allocPrintZ(self.allocator, "{s}", .{index_name});
        defer self.allocator.free(index_nt);

        const doc_id_nt = try std.fmt.allocPrintZ(self.allocator, "{s}", .{doc_id});
        defer self.allocator.free(doc_id_nt);

        const url = try std.fmt.allocPrintZ(self.allocator, "{s}/{s}/_doc/{s}", .{ self.base_url, index_nt, doc_id_nt });
        defer self.allocator.free(url);

        const doc_nt = try std.fmt.allocPrintZ(self.allocator, "{s}", .{document});
        defer self.allocator.free(doc_nt);

        // Reset CURL handle to default state
        c.curl_easy_reset(self.curl);

        // Set request specific options
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_URL, url.ptr) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_POSTFIELDS, doc_nt.ptr) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }
        if (c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEDATA, &response) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        // Add headers
        var headers: ?*c.curl_slist = null;
        headers = c.curl_slist_append(headers, "Content-Type: application/json");
        defer if (headers) |h| c.curl_slist_free_all(h);

        if (c.curl_easy_setopt(self.curl, c.CURLOPT_HTTPHEADER, headers) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        // Perform request
        const res = c.curl_easy_perform(self.curl);
        if (res != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        var response_code: c_long = undefined;
        _ = c.curl_easy_getinfo(self.curl, c.CURLINFO_RESPONSE_CODE, &response_code);
        if (response_code < 200 or response_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }
    }
};

// Tests

  

// Updated TestContext and mocks:
const TestContext = struct {
    mock_curl_response: []const u8 = "",
    mock_response_code: c_long = 200,
    mock_curl_error: c.CURLcode = c.CURLE_OK,
    write_data: ?*anyopaque = null,
    write_fn: ?*const fn ([*c]u8, c_uint, c_uint, *anyopaque) callconv(.C) c_uint = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{
            .allocator = allocator,
        };
    }
};

const test_ctx: TestContext = .{
    .allocator = undefined,
};

// Mock CURL functions
export fn mock_curl_easy_init() ?*c.CURL {
    return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(0x12345678))));
}

export fn mock_curl_easy_setopt(curl: *c.CURL, option: c.CURLoption, ptr: *const anyopaque) c.CURLcode {
    _ = curl;
    
    switch (option) {
        c.CURLOPT_WRITEFUNCTION => {
            const write_fn = @as(*const fn ([*c]u8, c_uint, c_uint, *anyopaque) callconv(.C) c_uint, @ptrCast(ptr));
            _ = write_fn;
        },
        c.CURLOPT_WRITEDATA => {
            const write_data = @as(*anyopaque, @constCast(ptr));
            _ = write_data;
        },
        else => {},
    }
    
    return test_ctx.mock_curl_error;
}

export fn mock_curl_easy_perform(curl: *c.CURL) c.CURLcode {
    _ = curl;
    if (test_ctx.mock_curl_error != c.CURLE_OK) {
        return test_ctx.mock_curl_error;
    }

    return c.CURLE_OK;
}

export fn mock_curl_easy_getinfo(curl: *c.CURL, info: c.CURLINFO, data: *c_long) c.CURLcode {
    _ = curl;
    _ = info;
    data.* = test_ctx.mock_response_code;
    return c.CURLE_OK;
}

export fn mock_curl_easy_cleanup(curl: *c.CURL) void {
    _ = curl;
}

export fn mock_curl_slist_append(list: ?*c.curl_slist, string: [*:0]const u8) ?*c.curl_slist {
    _ = list;
    _ = string;
    return @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(0x12345678))));
}

export fn mock_curl_slist_free_all(list: *c.curl_slist) void {
    _ = list;
}

// Test helper functions
fn createTestClient() !*OpenSearchClient {
    return try OpenSearchClient.getInstance(std.testing.allocator, "http://localhost:9200");
}

test "OpenSearchClient - getInstance creates singleton" {
    const client1 = try createTestClient();
    defer client1.deinit();
    
    const client2 = try OpenSearchClient.getInstance(std.testing.allocator, "http://localhost:9200");
    try std.testing.expect(client1 == client2);
}

test "OpenSearchClient - successful search" {
    const client = try createTestClient();
    defer client.deinit();

    const query = "{\"query\":{\"match_all\":{}}}";
    const result = try client.search("test_index", query);
    defer client.allocator.free(result);

    // We can still verify the operation completed
    try std.testing.expect(result.len > 0);
}

test "OpenSearchClient - failed search" {
    const client = try createTestClient();
    defer client.deinit();

    const query = "{\"query\":{\"match_all\":{}}}";
    const result = client.search("random", query);
    try std.testing.expectError(OpenSearchError.InvalidResponse, result);
}

test "OpenSearchClient - successful index" {
    const client = try createTestClient();
    defer client.deinit();

    const doc = "{\"title\":\"Test Document\"}";
    try client.index("test_index", "1", doc);
}

test "OpenSearchClient - failed index" {
    const client = try createTestClient();
    defer client.deinit();

    const doc = "{\"title\":\"Test Document\"}";
    const result = client.index("", "1", doc);
    try std.testing.expectError(OpenSearchError.InvalidResponse, result);
}