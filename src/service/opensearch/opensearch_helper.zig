const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
});

const log = std.log.scoped(.opensearch);

pub const OpenSearchError = error{
    InitError,
    RequestError,
    JsonError,
    InvalidResponse,
    OutOfMemory,
    URLError,
    CurlError,
    PayloadTooLarge,
};

pub const RequestMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
};

pub const ClientOptions = struct {
    connect_timeout_ms: c_long = 30000,
    request_timeout_ms: c_long = 30000,
    max_retries: u32 = 3,
    retry_delay_ms: c_long = 1000,
};

const CurlHandle = struct {
    curl: ?*c.CURL,
    in_use: bool,
};

pub const OpenSearchClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    base_url: []const u8,
    options: ClientOptions,

    // Thread-safe handle management
    mutex: std.Thread.Mutex,
    handles: std.AutoHashMap(std.Thread.Id, CurlHandle),

    const Response = struct {
        data: std.ArrayList(u8),
        allocator: std.mem.Allocator,
        status_code: c_long,

        pub fn init(allocator: std.mem.Allocator) Response {
            return .{
                .data = std.ArrayList(u8).init(allocator),
                .allocator = allocator,
                .status_code = 0,
            };
        }

        pub fn deinit(self: *Response) void {
            self.data.deinit();
        }

        pub fn toOwnedString(self: *Response) ![]const u8 {
            return self.data.toOwnedSlice();
        }
    };

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, options: ClientOptions) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const url_copy = try allocator.dupe(u8, base_url);
        errdefer allocator.free(url_copy);

        // Initialize the global CURL system
        if (c.curl_global_init(c.CURL_GLOBAL_ALL) != c.CURLE_OK) {
            return OpenSearchError.InitError;
        }

        self.* = .{
            .allocator = allocator,
            .base_url = url_copy,
            .options = options,
            .mutex = .{},
            .handles = std.AutoHashMap(std.Thread.Id, CurlHandle).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.handles.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.curl) |curl| {
                    c.curl_easy_cleanup(curl);
                }
            }
            self.handles.deinit();
        }

        self.allocator.free(self.base_url);
        c.curl_global_cleanup();
        self.allocator.destroy(self);
    }

    fn getThreadLocalCurl(self: *Self) !*c.CURL {
        const thread_id = std.Thread.getCurrentId();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we already have a handle for this thread
        if (self.handles.getPtr(thread_id)) |handle| {
            if (!handle.in_use) {
                handle.in_use = true;
                return handle.curl.?;
            }
        }

        // Create new handle
        const curl = c.curl_easy_init() orelse return OpenSearchError.InitError;
        errdefer c.curl_easy_cleanup(curl);

        // Set common CURL options
        if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK or
            c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK or
            c.curl_easy_setopt(curl, c.CURLOPT_CONNECTTIMEOUT_MS, self.options.connect_timeout_ms) != c.CURLE_OK or
            c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT_MS, self.options.request_timeout_ms) != c.CURLE_OK)
        {
            return OpenSearchError.InitError;
        }

        try self.handles.put(thread_id, .{
            .curl = curl,
            .in_use = true,
        });

        return curl;
    }

    fn releaseThreadLocalCurl(self: *Self, curl: *c.CURL) void {
        const thread_id = std.Thread.getCurrentId();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.handles.getPtr(thread_id)) |handle| {
            if (handle.curl == curl) {
                handle.in_use = false;
            }
        }
    }

    fn writeCallback(data: [*c]u8, size: c_uint, nmemb: c_uint, user_data: *Response) callconv(.C) c_uint {
        const real_size = size * nmemb;
        const slice = data[0..real_size];
        user_data.data.appendSlice(slice) catch return 0;
        return @intCast(real_size);
    }

    fn safeSizeToLong(size: usize) !c_long {
        if (size > std.math.maxInt(c_long)) {
            return OpenSearchError.PayloadTooLarge;
        }
        return @intCast(size);
    }

    fn performRequest(self: *Self, method: RequestMethod, path: []const u8, body: ?[]const u8, headers: ?[]const []const u8) !Response {
        const curl = try self.getThreadLocalCurl();
        defer self.releaseThreadLocalCurl(curl);

        var response = Response.init(self.allocator);
        errdefer response.deinit();

        // Build URL
        const url = try std.fmt.allocPrintZ(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);

        // Reset CURL handle to default state
        c.curl_easy_reset(curl);

        // Set common options
        try self.setCurlOptions(curl, url.ptr, method, body, &response);

        // Set headers
        var header_list: ?*c.curl_slist = null;
        defer if (header_list) |h| c.curl_slist_free_all(h);

        // Add default headers
        header_list = c.curl_slist_append(header_list, "Content-Type: application/json");

        // Add custom headers if provided
        if (headers) |h| {
            for (h) |header| {
                header_list = c.curl_slist_append(header_list, header.ptr);
            }
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return OpenSearchError.RequestError;
        }

        var retry_count: u32 = 0;
        while (retry_count <= self.options.max_retries) : (retry_count += 1) {
            const res = c.curl_easy_perform(curl);
            if (res == c.CURLE_OK) {
                _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response.status_code);

                // Check if we should retry based on status code
                if (response.status_code >= 500 and retry_count < self.options.max_retries) {
                    response.data.clearRetainingCapacity();
                    std.time.sleep(cLongToU64(self.options.retry_delay_ms) * std.time.ns_per_ms);
                    continue;
                }

                return response;
            } else if (retry_count < self.options.max_retries) {
                std.time.sleep(cLongToU64(self.options.retry_delay_ms) * std.time.ns_per_ms);
                continue;
            }

            return OpenSearchError.RequestError;
        }

        return OpenSearchError.RequestError;
    }
    pub fn cLongToU64(value: c_long) u64 {
        // First cast to i64 to handle both 32-bit and 64-bit c_long
        const as_i64: i64 = @as(i64, value);
        // Then convert to unsigned, handling negative values
        // return @bitCast( as_i64);
        return @as(u64, @bitCast(as_i64));
    }

    test "cLongToU64" {
        try std.testing.expect(cLongToU64(42) == 42);
        try std.testing.expect(cLongToU64(-1) == @as(u64, @bitCast(@as(i64, -1))));
    }
    fn setCurlOptions(
        self: *Self,
        curl: *c.CURL,
        url: [*:0]const u8,
        method: RequestMethod,
        body: ?[]const u8,
        response: *Response,
    ) !void {
        _ = c.curl_easy_setopt(curl, c.CURLOPT_URL, url);
        _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback);
        _ = c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, response);
        _ = c.curl_easy_setopt(curl, c.CURLOPT_CONNECTTIMEOUT_MS, self.options.connect_timeout_ms);
        _ = c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT_MS, self.options.request_timeout_ms);

        switch (method) {
            .GET => {
                _ = c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1));
            },
            .POST => {
                _ = c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1));
                if (body) |b| {
                    const body_size = try safeSizeToLong(b.len);
                    _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, b.ptr);
                    _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDSIZE, body_size);
                }
            },
            .PUT => {
                _ = c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "PUT");
                if (body) |b| {
                    const body_size = try safeSizeToLong(b.len);
                    _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, b.ptr);
                    _ = c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDSIZE, body_size);
                }
            },
            .DELETE => {
                _ = c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "DELETE");
            },
            .HEAD => {
                _ = c.curl_easy_setopt(curl, c.CURLOPT_NOBODY, @as(c_long, 1));
            },
        }
    }

    pub fn search(self: *Self, index_name: []const u8, query: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/_search", .{index_name});
        defer self.allocator.free(path);

        var response = try self.performRequest(.POST, path, query, null);
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }

        return response.toOwnedString();
    }

    pub fn index(self: *Self, index_name: []const u8, doc_id: []const u8, document: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}/_doc/{s}", .{ index_name, doc_id });
        defer self.allocator.free(path);

        var response = try self.performRequest(.PUT, path, document, null);
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }
    }

    pub fn bulk(self: *Self, body: []const u8) ![]const u8 {
        var response = try self.performRequest(.POST, "/_bulk", body, null);
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }

        return response.toOwnedString();
    }

    pub fn deleteIndex(self: *Self, index_name: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}", .{index_name});
        defer self.allocator.free(path);

        var response = try self.performRequest(.DELETE, path, null, null);
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }
    }

    pub fn createIndex(self: *Self, index_name: []const u8, settings: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/{s}", .{index_name});
        defer self.allocator.free(path);

        var response = try self.performRequest(.PUT, path, settings, null);
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            return OpenSearchError.InvalidResponse;
        }
    }
};

// Example of concurrent indexing
pub const ThreadContext = struct {
    client: *OpenSearchClient,
    index_name: []const u8,
    doc_id: []const u8,
    document: []const u8,
};

pub fn indexWorker(context: ThreadContext) !void {
    log.info("Thread indexing document {s}...", .{context.doc_id});
    try context.client.index(context.index_name, context.doc_id, context.document);
}
