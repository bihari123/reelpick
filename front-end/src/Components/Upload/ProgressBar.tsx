// src/components/Upload/components/ProgressBar.tsx

import React from "react";
import { formatFileSize } from "./utils/fileValidation";

interface ProgressBarProps {
	progress: number;
	fileSize: number;
	fileName: string;
	status: string;
	onCancel?: () => void;
}

const ProgressBar: React.FC<ProgressBarProps> = ({
	progress,
	fileSize,
	fileName,
	status,
	onCancel,
}) => {
	return (
		<div className="relative p-6 bg-gray-200 rounded-xl mt-5">
			<div className="flex">
				<div className="ml-2">
					<h1 className="font-medium">{fileName}</h1>
					<div className="text-left text-xs flex items-center space-x-3 text-gray-400 mt-0.5">
						<span>{formatFileSize(fileSize)}</span>
						<span className="p-0.5 h-0.5 rounded-full bg-gray-400"></span>
						<span>{status}</span>
					</div>
				</div>
			</div>

			<div
				className={`text-right mb-1 text-sm font-semibold ${progress === 100 ? "text-green-500" : ""}`}
			>
				{progress}%
			</div>

			<div className="flex justify-between items-center">
				<div className="flex-grow h-2 bg-gray-400 rounded relative">
					<div
						className={`h-2 rounded transition-all ${
							progress < 100 ? "bg-black" : "bg-green-500"
						}`}
						style={{ width: `${progress}%` }}
					></div>
				</div>

				{onCancel && progress < 100 && (
					<button
						onClick={onCancel}
						className="ml-4 text-gray-500 hover:text-gray-700"
					>
						Cancel
					</button>
				)}
			</div>
		</div>
	);
};

export default ProgressBar;
