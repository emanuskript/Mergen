"use client";

import { useCallback } from "react";
import { useDropzone } from "react-dropzone";

interface ZipUploaderProps {
  file: File | null;
  onFileChange: (file: File | null) => void;
}

export function ZipUploader({ file, onFileChange }: ZipUploaderProps) {
  const onDrop = useCallback(
    (accepted: File[]) => {
      if (accepted.length > 0) onFileChange(accepted[0]);
    },
    [onFileChange],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept: { "application/zip": [".zip"] },
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
          <p className="text-muted-foreground">
            Drop a ZIP archive of manuscript images, or click to select
          </p>
          <p className="mt-1 text-xs text-muted-foreground">ZIP files only</p>
        </div>
      )}
    </div>
  );
}
