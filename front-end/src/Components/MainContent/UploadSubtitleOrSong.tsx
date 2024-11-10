import React from "react";
import DoneImg from "../../assets/Component.svg";
import LoadingImg from "../../assets/Frame 130.svg";
import DownloadIcn from "../../assets/Download.svg";
import fileIcn from "../../assets/file-06.svg";
import cancelIcn from "../../assets/cancel-01.svg";
import tickIcn from "../../assets/check_circle.svg";
import Button from "../Button/Button";
interface UploadProgressProps {
  progress: number;
  step: "idle" | "analyzing" | "processing" | "finalizing" | "done";
  selectedFile: File;
  setSelectedFile: React.Dispatch<React.SetStateAction<File | null>>;
}

const UploadSubtitleOrSong: React.FC<UploadProgressProps> = ({
  progress,
  step,
  selectedFile,
  setSelectedFile,
}) => {
  const formatFileSize = (sizeInBytes: number) => {
    const units = ["Bytes", "KB", "MB", "GB", "TB"];
    let size = sizeInBytes;
    let unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return `${size.toFixed(2)} ${units[unitIndex]}`;
  };
  return (
    <>
      <div className="flex flex-col justify-between items-center w-full">
        <div className="relative border-2 bg-slate-50 p-2 rounded-3xl mb-4 w-10/12">
          <div className=" flex flex-col items-center justify-center">
            {step === "done" ? (
              <>
                <img src={DoneImg} alt="Done" className="w-16 h-16" />
                <p className="text-green-600 text-center font-semibold text-sm mt-0.5 ">
                  Done
                </p>
              </>
            ) : (
              <>
                <img src={LoadingImg} alt="Loading..." className="w-16 h-16" />
                <p className="text-black text-center font-medium text-sm mt-0.5">
                  {step === "analyzing"
                    ? "Analyzing your file..."
                    : step === "processing"
                      ? "Processing your file..."
                      : "Finalizing your file..."}
                </p>
              </>
            )}
          </div>
          <div className="relative p-6 bg-gray-200 rounded-xl mt-5">
            <div className="flex">
              <div className="w-8 h-auto">
                <img src={fileIcn} alt="fileIcn" />
              </div>
              <div className="ml-2">
                <h1>{selectedFile.name}</h1>
                <div className="text-left text-xs flex items-center space-x-3 text-gray-400 mt-0.5">
                  <span>{formatFileSize(selectedFile.size)}</span>
                  <span className="p-0.5 h-0.5 rounded-full bg-gray-400"></span>
                  <span>2 minutes left</span>
                </div>
              </div>
            </div>
            <div
              className={`text-right mb-1 text-sm font-semibold ${progress === 100 && "text-green-500"}`}
            >
              {progress}%
            </div>
            <div className="flex justify-between items-center">
              <div className="flex-grow h-2 bg-gray-400 rounded relative">
                <div
                  className={`h-2 rounded transition-all ${progress < 100 ? "bg-black" : "bg-green-500"}`}
                  style={{ width: `${progress}%` }}
                ></div>
              </div>

              <div className="ml-2">
                {progress === 100 && <img src={tickIcn} alt="tick" />}
              </div>
            </div>

            <div className="absolute top-6 right-5 cursor-pointer  hover:bg-black/5">
              <img
                src={cancelIcn}
                alt="cancelIcn"
                onClick={() => setSelectedFile(null)}
              />
            </div>
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
                <span className="text-semanticBlue font-semibold">CSV</span>{" "}
                format Available
              </p>
              <div className="absolute left-0 right-0 w-full h-0.5 bg-slate-200"></div>
            </div>
          </>
        )}
      </div>
    </>
  );
};
export default UploadSubtitleOrSong;
