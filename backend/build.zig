const std = @import("std");

// Build options for SQLite compilation
const sqlite_options = [_][]const u8{
    "-DSQLITE_THREADSAFE=1", // Enable thread safety
    "-DSQLITE_ENABLE_JSON1", // Enable JSON support
    "-DSQLITE_ENABLE_RTREE", // Enable R-Tree support
    "-DSQLITE_ENABLE_FTS5", // Enable Full Text Search
    "-DSQLITE_ENABLE_UNLOCK_NOTIFY", // Enable unlock notification
    "-DSQLITE_ENABLE_COLUMN_METADATA", // Enable column metadata access
    "-DSQLITE_ENABLE_STAT4", // Enable advanced query planner
    "-DSQLITE_ENABLE_MEMORY_MANAGEMENT", // Enable memory management
    "-DSQLITE_ENABLE_LOAD_EXTENSION", // Enable loading extensions
    "-DSQLITE_ENABLE_API_ARMOR", // Enable API armor
    "-DSQLITE_MAX_VARIABLE_NUMBER=250000", // Increase max variable number
    "-DSQLITE_MAX_EXPR_DEPTH=10000", // Increase expression depth limit
    "-DSQLITE_DEFAULT_CACHE_SIZE=-2000", // Set default cache size (2000 pages)
    "-DSQLITE_DEFAULT_SYNCHRONOUS=1", // Set synchronous mode to NORMAL
    "-DSQLITE_TEMP_STORE=2", // Store temp tables in memory
    "-DHAVE_USLEEP=1", // Enable microsecond sleep
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // Create the SQLite static library
    const sqlite = b.addStaticLibrary(.{
        .name = "sqlite3",
        .target = target,
        .optimize = optimize,
    });

    // Add SQLite source file with compilation options
    sqlite.addCSourceFile(.{
        .file = .{ .cwd_relative = "third_party/sqlite/sqlite3.c" },
        .flags = &sqlite_options,
    });
    sqlite.linkLibC();

    const lib = b.addStaticLibrary(.{
        .name = "reelpick",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "reelpick",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Link the executable with required libraries
    exe.linkSystemLibrary("hiredis");
    exe.linkSystemLibrary("curl");
    exe.linkLibrary(sqlite);
    exe.addIncludePath(.{ .cwd_relative = "third_party/sqlite" });

    exe.linkLibC();

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false, // set to true to enable TLS support
    });

    exe.root_module.addImport("zap", zap.module("zap"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Create test step
    const opensearch_tests = b.addTest(.{
        .root_source_file = b.path("src/file_server/service/opensearch/opensearch_helper.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the test executable with libcurl
    opensearch_tests.linkSystemLibrary("curl");
    opensearch_tests.linkLibC();

    const run_opensearch_tests = b.addRunArtifact(opensearch_tests);

    //Create the test executable
    const sqlite_test = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/file_server/service/sqlite/sqlite_helper.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Add SQLite C source
    sqlite_test.addCSourceFile(.{
        .file = .{ .cwd_relative = "third_party/sqlite/sqlite3.c" },
        .flags = &sqlite_options,
    });
    sqlite_test.addIncludePath(.{ .cwd_relative = "third_party/sqlite" });
    sqlite_test.linkLibC();

    // Create test step
    const run_sqlite_tests = b.addRunArtifact(sqlite_test);

    //Create the test executable
    const e2e_test = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/file_server/file_server_e2e_test.zig" },
        .target = target,
        .optimize = optimize,
    });
    e2e_test.root_module.addImport("zap", zap.module("zap"));
    // Link the executable with required libraries
    e2e_test.linkSystemLibrary("hiredis");
    e2e_test.linkSystemLibrary("curl");
    e2e_test.linkLibrary(sqlite);
    e2e_test.addIncludePath(.{ .cwd_relative = "third_party/sqlite" });

    const run_e2e_test = b.addRunArtifact(e2e_test);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_sqlite_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);

    test_step.dependOn(&run_opensearch_tests.step);
    test_step.dependOn(&run_e2e_test.step);
}
