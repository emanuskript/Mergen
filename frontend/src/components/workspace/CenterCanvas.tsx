"use client";

import { useEffect, useState } from "react";
import Image from "next/image";
import { useAtom, useAtomValue, useSetAtom } from "jotai";

import { FileUploader } from "@/components/analysis/FileUploader";
import { BatchGallery } from "@/components/results/BatchGallery";
import { InteractiveCanvas } from "@/components/results/InteractiveCanvas";
import { PanZoomImage } from "@/components/results/PanZoomImage";
import { COCOJson } from "@/lib/types/coco";
import {
  selectedFileAtom,
  fileCountAtom,
  addFilesAtom,
  colorMapAtom,
  selectedClassNamesAtom,
  inspectedAnnotationAtom,
  selectedBatchImageIndexAtom,
  editingAnnotationIdAtom,
  applyBboxEditAtom,
  applySegmentationEditAtom,
  effectiveCocoJsonAtom,
} from "@/lib/atoms";

/** Extract single-image COCO JSON from a merged batch COCO JSON by filename */
function extractImageCoco(merged: COCOJson, filename: string): COCOJson | null {
  const image = merged.images.find((img) => img.file_name === filename);
  if (!image) return null;
  return {
    info: merged.info,
    licenses: merged.licenses,
    images: [image],
    annotations: merged.annotations.filter((a) => a.image_id === image.id),
    categories: merged.categories,
  };
}

export function CenterCanvas() {
  const selectedFile = useAtomValue(selectedFileAtom);
  const fileCount = useAtomValue(fileCountAtom);
  const addFiles = useSetAtom(addFilesAtom);
  const colorMap = useAtomValue(colorMapAtom);
  const selectedClasses = useAtomValue(selectedClassNamesAtom);
  const inspectedAnnotation = useAtomValue(inspectedAnnotationAtom);
  const setInspectedAnnotation = useSetAtom(inspectedAnnotationAtom);
  const [selectedBatchImage, setSelectedBatchImage] = useAtom(selectedBatchImageIndexAtom);
  const editingAnnotationId = useAtomValue(editingAnnotationIdAtom);
  const setEditingAnnotationId = useSetAtom(editingAnnotationIdAtom);
  const applyBboxEdit = useSetAtom(applyBboxEditAtom);
  const applySegmentationEdit = useSetAtom(applySegmentationEditAtom);
  const effectiveCocoJson = useAtomValue(effectiveCocoJsonAtom);

  const [imageSrc, setImageSrc] = useState("");
  useEffect(() => {
    if (selectedFile?.kind !== "image") {
      setImageSrc("");
      return;
    }
    const url = URL.createObjectURL(selectedFile.file);
    setImageSrc(url);
    return () => URL.revokeObjectURL(url);
  }, [selectedFile?.file, selectedFile?.kind]);

  // ── No files at all: center drop zone ──
  if (fileCount === 0) {
    return (
      <div data-tour="canvas" style={{ gridArea: "canvas" }} className="flex items-center justify-center bg-muted/30">
        <div data-tour="file-upload" className="w-full max-w-md px-8">
          <FileUploader
            file={null}
            onFileChange={(f) => { if (f) addFiles([f]); }}
          />
        </div>
      </div>
    );
  }

  // ── No file selected ──
  if (!selectedFile) {
    return (
      <div style={{ gridArea: "canvas" }} className="flex items-center justify-center bg-muted/30">
        <p className="text-sm text-muted-foreground">Select a file from the list</p>
      </div>
    );
  }

  const mode = selectedFile.kind === "zip" ? "batch" : "single";

  // ── Single mode with results: InteractiveCanvas ──
  if (mode === "single" && selectedFile.singleResult && effectiveCocoJson) {
    return (
      <div style={{ gridArea: "canvas" }} className="relative overflow-hidden bg-muted/30">
        <InteractiveCanvas
          imageSrc={imageSrc}
          cocoJson={effectiveCocoJson}
          colorMap={colorMap}
          selectedClasses={selectedClasses}
          onAnnotationClick={(ann) => {
            if (!ann || ann.id !== editingAnnotationId) {
              setEditingAnnotationId(null);
            }
            setInspectedAnnotation(ann);
          }}
          selectedAnnotationId={inspectedAnnotation?.id ?? null}
          editingAnnotationId={editingAnnotationId}
          onBboxChange={(annotationId, bbox) =>
            applyBboxEdit({ fileId: selectedFile.id, annotationId, bbox })
          }
          onSegmentationChange={(annotationId, segmentation, bbox) =>
            applySegmentationEdit({ fileId: selectedFile.id, annotationId, segmentation, bbox })
          }
        />
      </div>
    );
  }

  // ── Batch mode with results ──
  if (mode === "batch" && selectedFile.batchResults) {
    const gallery = selectedFile.batchResults.gallery;

    // Detail view — single batch image selected from left panel
    if (selectedBatchImage !== null && gallery[selectedBatchImage]) {
      const item = gallery[selectedBatchImage];

      // Try to use InteractiveCanvas with original image + per-image COCO
      const originalSrc = selectedFile.extractedImages?.get(item.filename) ?? null;
      const perImageCoco = extractImageCoco(selectedFile.batchResults!.coco_json, item.filename);
      const useInteractive = originalSrc && perImageCoco;

      return (
        <div style={{ gridArea: "canvas" }} className="relative overflow-hidden bg-muted/30">
          {useInteractive ? (
            <InteractiveCanvas
              imageSrc={originalSrc}
              cocoJson={perImageCoco}
              colorMap={colorMap}
              selectedClasses={selectedClasses}
              onAnnotationClick={setInspectedAnnotation}
            />
          ) : (
            <PanZoomImage src={item.annotated_url} alt={item.filename} />
          )}
        </div>
      );
    }

    // Gallery grid
    return (
      <div style={{ gridArea: "canvas" }} className="overflow-y-auto bg-muted/30 p-4">
        <BatchGallery
          gallery={selectedFile.batchResults.gallery}
          statsPerImage={selectedFile.batchResults.stats_per_image}
          selected={selectedBatchImage}
          onSelect={setSelectedBatchImage}
        />
      </div>
    );
  }

  // ── Analyzing: preview with loading overlay ──
  if (selectedFile.status === "analyzing") {
    return (
      <div style={{ gridArea: "canvas" }} className="relative flex items-center justify-center overflow-hidden bg-muted/30 p-8">
        {mode === "single" && imageSrc ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={imageSrc}
            alt="Preview"
            className="max-h-full max-w-full rounded-lg object-contain opacity-50 shadow-sm"
          />
        ) : (
          <div className="flex flex-col items-center gap-3 rounded-lg border bg-card p-8 shadow-sm opacity-50">
            <div className="flex h-16 w-16 items-center justify-center rounded-full bg-muted">
              <svg className="h-8 w-8 text-muted-foreground" fill="none" stroke="currentColor" strokeWidth={1.5} viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
              </svg>
            </div>
            <p className="text-sm font-medium">{selectedFile.file.name}</p>
          </div>
        )}
        {/* Loading spinner overlay */}
        <div className="absolute inset-0 flex items-center justify-center bg-background/30">
          <div className="flex flex-col items-center gap-2">
            <svg className="h-8 w-8 animate-spin text-primary" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
            </svg>
            <span className="text-sm text-muted-foreground">Analyzing...</span>
          </div>
        </div>
      </div>
    );
  }

  // ── Error state ──
  if (selectedFile.status === "error") {
    return (
      <div style={{ gridArea: "canvas" }} className="relative flex items-center justify-center overflow-hidden bg-muted/30 p-8">
        {mode === "single" && imageSrc ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={imageSrc}
            alt="Preview"
            className="max-h-full max-w-full rounded-lg object-contain opacity-30 shadow-sm"
          />
        ) : null}
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="rounded-lg bg-card p-4 text-center shadow-sm">
            <p className="text-sm font-medium text-destructive">Analysis failed</p>
            {selectedFile.error && (
              <p className="mt-1 text-xs text-muted-foreground">{selectedFile.error}</p>
            )}
          </div>
        </div>
      </div>
    );
  }

  // ── Idle: preview ──
  return (
    <div style={{ gridArea: "canvas" }} className="relative flex items-center justify-center overflow-hidden bg-muted/30 p-8">
      {mode === "single" && imageSrc ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={imageSrc}
          alt="Preview"
          className="max-h-full max-w-full rounded-lg object-contain shadow-sm"
        />
      ) : (
        <div className="flex flex-col items-center gap-3 rounded-lg border bg-card p-8 shadow-sm">
          <div className="flex h-16 w-16 items-center justify-center rounded-full bg-muted">
            <svg className="h-8 w-8 text-muted-foreground" fill="none" stroke="currentColor" strokeWidth={1.5} viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
            </svg>
          </div>
          <div className="text-center">
            <p className="text-sm font-medium">{selectedFile.file.name}</p>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {(selectedFile.file.size / 1024 / 1024).toFixed(2)} MB — ZIP archive
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
