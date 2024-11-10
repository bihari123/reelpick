// src/Components/MainContent/MainContent.tsx

import React, { useState } from "react";
import UploadForm from "../Upload/UploadForm";
import UploadSubtitleOrSong from "./UploadSubtitleOrSong";
import { ProcessingStep, UploadStatus } from "../Upload/utils/upload.types";
import { FileUploadService } from "../Upload/services/fileUploadService";

const MainContent = () => {
	const [uploading, setUploading] = useState(false);
	const [progress, setProgress] = useState(0);
	const [processingStep, setProcessingStep] = useState<ProcessingStep>(null);
	const [selectedFile, setSelectedFile] = useState<File | null>(null);
	const uploadService = new FileUploadService();

	const handleFileSelect = async (file: File) => {
		setSelectedFile(file);
		setUploading(true);
		setProcessingStep("analyzing");
		setProgress(0);

		try {
			await uploadService.uploadFile(file, {
				onProgress: (progressValue) => {
					setProgress(progressValue);
				},
				onStatusChange: (status) => {
					setProcessingStep(status);
				},
				onSuccess: () => {
					setUploading(false);
					setProcessingStep("done");
				},
				onError: (error: Error) => {
					console.error("Upload failed:", error);
					setUploading(false);
					setProcessingStep(null);
					alert("Upload failed: " + error.message);
				},
			});
		} catch (error) {
			console.error("Upload failed:", error);
			setUploading(false);
			setProcessingStep(null);
			alert("Upload failed. Please try again.");
		}
	};

	return (
		<main className="flex-grow">
			<div className="max-w-4xl mx-auto text-center py-12 font-inter">
				<h1 className="text-4xl font-bold text-gray-800 mb-6">
					AI-Powered{" "}
					<span className="text-transparent bg-gradient-emotion bg-clip-text">
						Highlights
					</span>{" "}
					Detector
				</h1>
				<p className="text-lg text-gray-600 mb-10">
					Upload your video and let our AI analyze the score impact of each
					scene.
				</p>

				{!uploading && !selectedFile ? (
					<UploadForm onFileSelect={handleFileSelect} />
				) : (
					<UploadSubtitleOrSong
						progress={progress}
						step={processingStep || "analyzing"} // Provide default value when null
						selectedFile={selectedFile as File}
						setSelectedFile={setSelectedFile}
					/>
				)}

				<section className="mt-28">
					<h2 className="text-2xl font-semibold text-gray-700 mb-4">
						- Introduction -
					</h2>
					<p className="text-gray-500 text-base">
						Welcome to our AI-powered video analysis tool! Our AI models are
						designed to analyze your video scene-by-scene, detecting and
						analyzing key moments, and determining how each scene may impact
						viewers. Start your journey by uploading a video, and the AI will
						break down the your content and provide insights.
					</p>
				</section>
			</div>
		</main>
	);
};

export default MainContent;
