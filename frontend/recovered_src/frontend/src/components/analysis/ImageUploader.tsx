"use client";

import { useCallback } from "react";
import { useDropzone } from "react-dropzone";

interface ImageUploaderProps {
  file: File | null;
  onFileChange: (file: File | null) => void;
  accept?: Record<string, string[]>;
  label?: string;
}

export function ImageUploader({
  file,
  onFileChange,
  accept = { "image/*": [".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"] },
  label = "Drop a manuscript image here, or click to select",
}: ImageUploaderProps) {
  const onDrop = useCallback(
    (accepted: File[]) => {
      if (accepted.length > 0) onFileChange(accepted[0]);
    },
    [onFileChange],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept,
    maxFiles: 1,
  });

  return (
    <div
      {...getRootProps()}
      className={`cursor-pointer rounded-lg border-2 border-dashed p-8 text-center transition-colors ${
        isDragActive ? "border-primary bg-primary/5" : "border-muted-foreground/25 hover:border-primary/50"
      }`}
    >
      <input {...getInputProps()} />
      {file ? (
        <div>
          <p className="font-medium">{file.name}</p>
          <p className="text-sm text-muted-foreground">
            {(file.size / 1024 / 1024).toFixed(2)} MB
          </p>
          <p className="mt-2 text-xs text-muted-foreground">Click or drop to replace</p>
        </div>
      ) : (
        <div>
          <p className="text-muted-foreground">{label}</p>
          <p className="mt-1 text-xs text-muted-foreground">
            PNG, JPG, JPEG, BMP, TIF, TIFF, WebP
          </p>
        </div>
      )}
    </div>
  );
}
