// src/components/Upload/hooks/useFileUpload.ts

import { useState, useCallback } from "react";
import { FileUploadService } from "../services/fileUploadService";
import { UploadStatus } from "../utils/upload.types";
import { UPLOAD_CONFIG } from "../utils/upload.constants";
import { validateFile } from "../utils/fileValidation";

interface UseFileUploadReturn {
	progress: number;
	status: UploadStatus;
	error: string | null;
	isUploading: boolean;
	uploadFile: (file: File) => Promise<void>;
	resetUpload: () => void;
}

export const useFileUpload = (): UseFileUploadReturn => {
	const [progress, setProgress] = useState<number>(0);
	const [status, setStatus] = useState<UploadStatus>("idle");
	const [error, setError] = useState<string | null>(null);
	const [isUploading, setIsUploading] = useState<boolean>(false);

	const uploadService = new FileUploadService();

	const resetUpload = useCallback(() => {
		setProgress(0);
		setStatus("idle");
		setError(null);
		setIsUploading(false);
	}, []);

	const uploadFile = useCallback(async (file: File) => {
		try {
			const validationError = validateFile(file);
			if (validationError) {
				setError(validationError);
				return;
			}

			setIsUploading(true);
			setError(null);

			await uploadService.uploadFile(file, {
				onProgress: setProgress,
				onStatusChange: setStatus,
				onSuccess: () => {
					setIsUploading(false);
					setStatus("done");
				},
				onError: (error) => {
					setError(error.message);
					setIsUploading(false);
					setStatus("idle");
				},
			});
		} catch (error) {
			setError((error as Error).message);
			setIsUploading(false);
			setStatus("idle");
		}
	}, []);

	return {
		progress,
		status,
		error,
		isUploading,
		uploadFile,
		resetUpload,
	};
};
