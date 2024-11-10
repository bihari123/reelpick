// src/components/Upload/utils/fileValidation.ts

import { UPLOAD_CONFIG } from "../utils/upload.constants";

export const validateFile = (file: File): string | null => {
	// Check file size
	if (file.size > UPLOAD_CONFIG.MAX_FILE_SIZE) {
		return `File size (${formatFileSize(file.size)}) exceeds maximum limit of ${formatFileSize(UPLOAD_CONFIG.MAX_FILE_SIZE)}`;
	}

	// Check file type
	const fileExtension = file.name.toLowerCase().split(".").pop();
	if (
		!fileExtension ||
		!UPLOAD_CONFIG.ALLOWED_TYPES.includes(`.${fileExtension}`)
	) {
		return `File type .${fileExtension} is not supported. Please upload ${UPLOAD_CONFIG.ALLOWED_TYPES.join(" or ")} file`;
	}

	return null;
};

export const formatFileSize = (bytes: number): string => {
	const units = ["B", "KB", "MB", "GB"];
	let size = bytes;
	let unitIndex = 0;

	while (size >= 1024 && unitIndex < units.length - 1) {
		size /= 1024;
		unitIndex++;
	}

	return `${size.toFixed(2)} ${units[unitIndex]}`;
};
