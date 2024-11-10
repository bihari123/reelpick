import React from "react";
import thumbnailImg from "../../assets/image.png";
import LoadingImg from "../../assets/Frame 130.svg";
import timelapse from "../../assets/timelapse.svg";
import Button from "../Button/Button";
import DownloadIcn from "../../assets/Download.svg";
import DoneImg from "../../assets/Component.svg";
interface UploadProgressProps {
	progress: number;
	step: "analyzing" | "processing" | "finalizing" | "done";
}

const UploadVideoProgress: React.FC<UploadProgressProps> = ({
	progress,
	step,
}) => (
	<div className="flex flex-col justify-between items-center w-full">
		<div className="relative border-2 bg-slate-50 p-2 rounded-3xl mb-4 w-10/12">
			<img src={thumbnailImg} alt="thumbnail" className="w-full mx-auto" />
			<div className="absolute left-1/2 top-1/2 transform -translate-x-1/2 -translate-y-1/2 z-10 flex flex-col items-center justify-center">
				{step === "done" ? (
					<>
						<img src={DoneImg} alt="Done" className="w-16 h-16" />
						<p className="text-white text-center font-normal">Done</p>
					</>
				) : (
					<>
						<img src={LoadingImg} alt="Loading..." className="w-16 h-16" />
						<p className="text-white text-center font-normal">
							{step === "analyzing"
								? "Analyzing your video..."
								: step === "processing"
									? "Processing your video..."
									: "Finalizing your video..."}
						</p>
					</>
				)}
			</div>
		</div>

		<div className="flex justify-between items-center text-left w-10/12 mb-8">
			<div className="w-1/2">
				Upload your video and let our AI find the highlights for the game scene.
			</div>
			<div className="flex flex-col">
				<div className="flex items-center justify-center">
					<span className="mr-1">6:16</span>
					<img src={timelapse} alt="timelapse icon" className="mr-2" />
					<span className="p-1.5 bg-slate-100 text-green-500 font-bold rounded-md">
						325 MB
					</span>
				</div>
				<div className="text-left">{progress}% completed</div>
			</div>
		</div>

		{step === "done" && (
			<>
				<div className="">
					<div className="absolute left-0 right-0 w-full h-0.5 bg-slate-200"></div>
					<Button
						className="bg-green-500 text-white py-2 px-6 rounded hover:bg-green-600 flex items-center justify-center mx-auto mt-14"
						onClick={() => alert("Downloading report...")}
					>
						Download Report
						<img src={DownloadIcn} alt="Download" className="ml-2" />
					</Button>
					<p className="mt-2 mb-12">
						<span className="text-semanticBlue font-semibold">PDF </span>or{" "}
						<span className="text-semanticBlue font-semibold">CSV</span> format
						Available
					</p>
					<div className="absolute left-0 right-0 w-full h-0.5 bg-slate-200"></div>
				</div>
			</>
		)}
	</div>
);

export default UploadVideoProgress;
