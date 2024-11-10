// src/Components/services/fileUploadService.ts

import {
	UploadProgressCallback,
	ChunkUploadResponse,
	UploadInitializeResponse,
} from "../utils/upload.types";

const API_BASE_URL = "http://0.0.0.0:8080";

const API_TOKEN = "tk_1234567890abcdef";
export class FileUploadService {
	private async initializeUpload(
		file: File,
	): Promise<UploadInitializeResponse> {
		console.log("Initializing upload for file:", file.name);

		const requestData = {
			fileName: file.name,
			fileSize: file.size,
			totalChunks: Math.ceil(file.size / (1024 * 1024)), // 1MB chunks
		};

		console.log("Request data:", requestData);

		try {
			const response = await fetch(`${API_BASE_URL}/api/upload/initialize`, {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
					Accept: "application/json",
					Authorization: `Bearer ${API_TOKEN}`,
				},
				body: JSON.stringify(requestData),
			});

			console.log("Raw response:", response);
			const responseText = await response.text();
			console.log("Response text:", responseText);

			if (!responseText) {
				throw new Error("Empty response received from server");
			}

			const data = JSON.parse(responseText);
			console.log("Parsed response:", data);

			if (!response.ok) {
				throw new Error(data.error || `Server error: ${response.status}`);
			}

			if (!data.fileId) {
				throw new Error("Invalid response: missing fileId");
			}

			return {
				fileId: data.fileId,
				fileName: data.fileName || file.name,
				fileSize: data.fileSize || file.size,
			};
		} catch (error) {
			console.error("Initialize upload error:", error);
			throw error;
		}
	}

	private async uploadChunk(
		chunk: Blob,
		chunkIndex: number,
		totalChunks: number,
		fileId: string,
	): Promise<ChunkUploadResponse> {
		console.log(`Uploading chunk ${chunkIndex + 1}/${totalChunks}`);

		try {
			const response = await fetch(`${API_BASE_URL}/api/upload/chunk`, {
				method: "POST",
				headers: {
					"X-File-Id": fileId,
					"X-Chunk-Index": chunkIndex.toString(),
					Accept: "application/json",
					"Content-Type": "application/octet-stream",
					Authorization: `Bearer ${API_TOKEN}`,
				},
				body: chunk, // Send raw chunk data
			});

			console.log(`Chunk ${chunkIndex} response status:`, response.status);
			const responseText = await response.text();
			console.log(`Chunk ${chunkIndex} response:`, responseText);

			if (!responseText) {
				throw new Error("Empty response received from server");
			}

			const data = JSON.parse(responseText);
			console.log(`Chunk ${chunkIndex} parsed response:`, data);

			if (!response.ok) {
				throw new Error(
					data.error || `Chunk upload failed: ${response.status}`,
				);
			}

			if (!data.received) {
				throw new Error(data.error || "Chunk upload failed");
			}

			return {
				received: data.received,
				status: data.status,
				progress: data.progress,
				uploadedSize: data.uploadedSize,
				totalSize: data.totalSize,
				message: data.message,
			};
		} catch (error) {
			console.error(`Failed to upload chunk ${chunkIndex}:`, error);
			throw error;
		}
	}

	public async uploadFile(
		file: File,
		callbacks: UploadProgressCallback,
	): Promise<void> {
		try {
			console.log("Starting upload for file:", file.name);

			// Initialize upload
			const initResponse = await this.initializeUpload(file);
			console.log("Upload initialized:", initResponse);

			const CHUNK_SIZE = 1024 * 1024; // 1MB
			const totalChunks = Math.ceil(file.size / CHUNK_SIZE);
			let uploadedChunks = 0;

			callbacks.onStatusChange("analyzing");

			// Upload chunks
			for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
				const start = chunkIndex * CHUNK_SIZE;
				const end = Math.min(start + CHUNK_SIZE, file.size);
				const chunk = file.slice(start, end);

				console.log(
					`Uploading chunk ${chunkIndex + 1}/${totalChunks} (${start}-${end})`,
				);

				const response = await this.uploadChunk(
					chunk,
					chunkIndex,
					totalChunks,
					initResponse.fileId,
				);

				uploadedChunks++;
				callbacks.onProgress(response.progress);
				callbacks.onStatusChange(response.status);

				console.log(
					`Chunk ${chunkIndex + 1} uploaded successfully. Progress: ${response.progress}%`,
				);
			}

			console.log("Upload completed successfully");
			callbacks.onStatusChange("done");
			callbacks.onSuccess();
		} catch (error) {
			console.error("Upload failed:", error);
			callbacks.onError(
				error instanceof Error ? error : new Error(String(error)),
			);
		}
	}
}
