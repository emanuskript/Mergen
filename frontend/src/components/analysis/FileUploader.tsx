"use client";

import { useCallback } from "react";
import Image from "next/image";
import { useDropzone } from "react-dropzone";

interface FileUploaderProps {
  file: File | null;
  onFileChange: (file: File | null) => void;
}

const ACCEPT = {
  "image/*": [".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp"],
  "application/zip": [".zip"],
};

function isZip(file: File): boolean {
  return (
    file.type === "application/zip" ||
    file.type === "application/x-zip-compressed" ||
    file.name.toLowerCase().endsWith(".zip")
  );
}

export function FileUploader({ file, onFileChange }: FileUploaderProps) {
  const onDrop = useCallback(
    (accepted: File[]) => {
      if (accepted.length > 0) onFileChange(accepted[0]);
    },
    [onFileChange],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept: ACCEPT,
    maxFiles: 1,
  });

  return (
    <div
      {...getRootProps()}
      className={`relative cursor-pointer rounded-lg border-2 border-dashed p-6 text-center transition-colors ${
        isDragActive
          ? "border-primary bg-primary/5"
          : "border-muted-foreground/25 hover:border-primary/50"
      }`}
    >
      <input {...getInputProps()} />
      {file ? (
        <div>
          <div className="mb-1 flex items-center justify-center gap-1.5">
            {isZip(file) ? (
              <svg className="h-4 w-4 text-muted-foreground" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
              </svg>
            ) : (
              <svg className="h-4 w-4 text-muted-foreground" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z" />
              </svg>
            )}
            <p className="text-sm font-medium truncate">{file.name}</p>
          </div>
          <p className="text-xs text-muted-foreground">
            {(file.size / 1024 / 1024).toFixed(2)} MB
            {isZip(file) ? " — Batch mode" : " — Single image"}
          </p>
          <p className="mt-1.5 text-xs text-muted-foreground">Click or drop to replace</p>
        </div>
      ) : (
        <div>
          <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center -translate-y-[257px]">
            <Image
              src="/mergen.png"
              alt="Mergen"
              width={520}
              height={180}
              priority
              className="h-auto w-full max-w-[360px] opacity-15"
            />
          </div>
          <div className="relative z-10">
          <svg className="mx-auto mb-2 h-8 w-8 text-muted-foreground/40" fill="none" stroke="currentColor" strokeWidth={1.5} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />
          </svg>
          <p className="text-sm text-muted-foreground">
            Drop an image or ZIP archive
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            Image for single analysis, ZIP for batch
          </p>
          </div>
        </div>
      )}
    </div>
  );
}

/** Utility to detect mode from a file */
export function detectMode(file: File | null): "single" | "batch" {
  if (!file) return "single";
  return isZip(file) ? "batch" : "single";
}
