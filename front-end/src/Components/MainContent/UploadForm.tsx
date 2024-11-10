import React, { useRef, useState } from "react";
import Button from "../Button/Button";
import upload from "../../assets/Upload.svg";

interface UploadFormProps {
  onFileSelect: (file: File) => void;
}

const UploadForm: React.FC<UploadFormProps> = ({ onFileSelect }) => {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [dragging, setDragging] = useState(false);
  const maxSize = 500 * 1024 * 1024; // 500MB

  const openFileDialog = () => {
    if (fileInputRef.current) {
      fileInputRef.current.click();
    }
  };

  const handleFileChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file && validateFile(file)) {
      onFileSelect(file);
    }
  };

  const handleDrop = (event: React.DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    event.stopPropagation();
    setDragging(false);

    const file = event.dataTransfer.files?.[0];
    if (file && validateFile(file)) {
      onFileSelect(file);
    }
  };

  const handleDragOver = (event: React.DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragging(true);
  };

  const handleDragLeave = () => {
    setDragging(false);
  };

  const validateFile = (file: File) => {
    const fileType = file.type;
    const fileSize = file.size;

    if (
      fileType !== "application/x-subrip" /*&& !file.name.endsWith('.srt')*/
    ) {
      alert("Please upload a valid .srt file.");
      return false;
    }
    if (fileSize > maxSize) {
      alert("File size exceeds 500MB.");
      return false;
    }
    return true;
  };

  return (
    <div
      className={`border-2 border-dashed border-green-500 rounded-lg p-12 bg-white 
        ${dragging ? "border-green-600" : ""}`}
      onDrop={handleDrop}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
    >
      <div className="flex justify-center items-center mb-4 border-2 border-green-500 h-16 w-16 rounded-2xl mx-auto shadow-outside-custom">
        <img src={upload} alt="upload" className="h-16 w-16" />
      </div>
      <p className="text-gray-500 mb-4">Drag & Drop or Choose file to upload</p>
      <p className="text-sm text-gray-400">
        Supported formats: .srt (Max size: 500MB)
      </p>

      <input
        ref={fileInputRef}
        type="file"
        accept=".srt"
        onChange={handleFileChange}
        style={{ display: "none" }}
      />
      <Button
        className="mt-4 bg-green-500 text-white py-2 px-6 rounded hover:bg-green-600"
        onClick={openFileDialog}
      >
        Upload Now
      </Button>
    </div>
  );
};

export default UploadForm;
