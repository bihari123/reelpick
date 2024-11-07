const std = @import("std");

// File upload settings
const UPLOAD_DIR = "uploads";
const MAX_FILE_SIZE = 1000 * 1024 * 1024; // 1000MB
const CHUNK_SIZE = 1024 * 1024; // 1MB

const UploadError = error{
    InvalidRequestBody,
    FileTooLarge,
    FileIdGenerationFailed,
    CreateSessionFailed,
    StoreSessionFailed,
    MissingFileId,
    MissingChunkIndex,
    MissingChunkData,
    FileSizeExceeded,
    WriteChunkFailed,
    FinalizeUploadFailed,
    InvalidSession,
    Unauthorized,
    RedisError,
};

// API token validation
const API_TOKENS = struct {
    const tokens = [_][]const u8{
        "tk_1234567890abcdef",
        "tk_0987654321fedcba",
    };

    pub fn isValid(token: []const u8) bool {
        for (tokens) |valid_token| {
            if (std.mem.eql(u8, token, valid_token)) {
                return true;
            }
        }
        return false;
    }
};
