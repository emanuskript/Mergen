import { BatchProgress, BatchResults, PredictSingleResponse } from "../types/predict";

export type FileEntryStatus = "idle" | "analyzing" | "done" | "error";

export type FileEntryKind = "image" | "zip";

export interface FileEntry {
  /** Stable unique id */
  id: string;
  /** The actual File object from the browser */
  file: File;
  /** "image" or "zip", determined at add time */
  kind: FileEntryKind;
  /** Object URL for thumbnail preview (images only) */
  thumbnailUrl: string | null;
  /** Per-file confidence threshold */
  confidence: number;
  /** Per-file IoU threshold */
  iou: number;

  // Runtime state
  status: FileEntryStatus;
  error: string | null;

  // Single-image results (kind === "image")
  singleResult: PredictSingleResponse | null;

  // Batch results (kind === "zip")
  batchProgress: BatchProgress | null;
  batchResults: BatchResults | null;
  batchTaskId: string | null;

  /** Extracted original images from ZIP (filename → blob URL) */
  extractedImages: Map<string, string> | null;
}
