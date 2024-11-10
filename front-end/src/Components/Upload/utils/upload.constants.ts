// src/components/Upload/constants/upload.constants.ts

export const UPLOAD_CONFIG = {
	CHUNK_SIZE: 1024 * 1024, // 1MB
	MAX_FILE_SIZE: 500 * 1024 * 1024, // 500MB
	ALLOWED_TYPES: ["*"],
	RETRY_ATTEMPTS: 3,
	RETRY_DELAY: 1000, // 1 second
};

export const UPLOAD_STAGES = {
	IDLE: { threshold: 30, status: "idle" as const },
	ANALYZING: { threshold: 30, status: "analyzing" as const },
	PROCESSING: { threshold: 60, status: "processing" as const },
	FINALIZING: { threshold: 100, status: "finalizing" as const },
	DONE: { threshold: 100, status: "done" as const },
};

export const ERROR_MESSAGES = {
	FILE_TOO_LARGE: "File size exceeds 500MB limit",
	INVALID_TYPE: "Please upload a valid .srt file",
	UPLOAD_FAILED: "Upload failed. Please try again",
	NETWORK_ERROR: "Network error occurred. Please check your connection",
	VERIFICATION_FAILED: "File verification failed",
};
