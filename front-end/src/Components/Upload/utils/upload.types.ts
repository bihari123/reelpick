// src/Components/types/upload.types.ts
export type ProcessingStep =
	| "idle"
	| "analyzing"
	| "processing"
	| "finalizing"
	| "done"
	| null;
export type UploadStatus =
	| "idle"
	| "analyzing"
	| "processing"
	| "finalizing"
	| "done";

export interface UploadFormProps {
	onFileSelect: (file: File) => void;
}

export interface UploadProgressProps {
	progress: number;
	status: UploadStatus;
	selectedFile: File;
	setSelectedFile: React.Dispatch<React.SetStateAction<File | null>>;
}

export interface UploadProgressCallback {
	onProgress: (progress: number) => void;
	onError: (error: Error) => void;
	onSuccess: () => void;
	onStatusChange: (status: UploadStatus) => void;
}

export interface ChunkUploadResponse {
	received: boolean;
	status: UploadStatus;
	progress: number;
	uploadedSize: number;
	totalSize: number;
	message?: string;
}

export interface UploadInitializeResponse {
	fileId: string;
	fileName: string;
	fileSize: number;
}

export interface UploadConfig {
	chunkSize: number;
	maxFileSize: number;
	allowedTypes: string[];
	baseUrl: string;
}
