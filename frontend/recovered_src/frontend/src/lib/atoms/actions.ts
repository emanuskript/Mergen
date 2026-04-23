import { atom } from "jotai";
import JSZip from "jszip";
import { predictSingle, predictBatch, getBatchResults } from "../api/predict";
import { subscribeBatchProgress } from "../api/sse";
import {
  fileEntriesAtom,
  updateFileEntryAtom,
  resetAllFilesAtom,
} from "./files";
import {
  classesAtom,
  selectedClassNamesArrayAtom,
} from "./classes";
import {
  inspectedAnnotationAtom,
  selectedBatchImageIndexAtom,
} from "./ui";

// Store for SSE unsubscribe functions (keyed by file id)
const sseUnsubscribers = new Map<string, () => void>();

const IMAGE_EXTS = /\.(png|jpe?g|bmp|tiff?|webp)$/i;

/** Extract original images from a ZIP File → Map<filename, blobURL> */
async function extractImagesFromZip(zipFile: File): Promise<Map<string, string>> {
  const zip = await JSZip.loadAsync(zipFile);
  const map = new Map<string, string>();
  const entries = Object.entries(zip.files).filter(
    ([name, f]) => !f.dir && IMAGE_EXTS.test(name) && !name.startsWith("__MACOSX"),
  );
  await Promise.all(
    entries.map(async ([name, f]) => {
      const blob = await f.async("blob");
      map.set(name.replace(/^.*\//, ""), URL.createObjectURL(blob));
    }),
  );
  return map;
}

// ── Run prediction for a single file entry ──
export const runFileAtom = atom(null, async (get, set, fileId: string) => {
  const entries = get(fileEntriesAtom);
  const entry = entries.find((e) => e.id === fileId);
  if (!entry || entry.status === "analyzing") return;

  const classes = get(classesAtom);
  const selectedNames = get(selectedClassNamesArrayAtom);
  const cls = selectedNames.length < classes.length ? selectedNames : undefined;

  // Clear previous results
  set(updateFileEntryAtom, {
    id: fileId,
    patch: {
      status: "analyzing",
      error: null,
      singleResult: null,
      batchResults: null,
      batchProgress: null,
      batchTaskId: null,
    },
  });

  if (entry.kind === "image") {
    try {
      const result = await predictSingle(entry.file, entry.confidence, entry.iou, cls);
      set(updateFileEntryAtom, {
        id: fileId,
        patch: { status: "done", singleResult: result },
      });
    } catch (err) {
      set(updateFileEntryAtom, {
        id: fileId,
        patch: {
          status: "error",
          error: err instanceof Error ? err.message : "Prediction failed",
        },
      });
    }
  } else {
    // ZIP / batch
    try {
      const { task_id } = await predictBatch(entry.file, entry.confidence, entry.iou, cls);
      set(updateFileEntryAtom, {
        id: fileId,
        patch: { batchTaskId: task_id },
      });

      // Clean up any previous SSE for this file
      sseUnsubscribers.get(fileId)?.();

      const unsub = subscribeBatchProgress(
        task_id,
        async (data) => {
          set(updateFileEntryAtom, {
            id: fileId,
            patch: { batchProgress: data },
          });
          if (data.status === "completed") {
            try {
              const res = await getBatchResults(task_id);
              set(updateFileEntryAtom, {
                id: fileId,
                patch: { status: "done", batchResults: res },
              });
              // Extract original images from ZIP for interactive canvas
              const currentEntries = get(fileEntriesAtom);
              const currentEntry = currentEntries.find((e) => e.id === fileId);
              if (currentEntry) {
                try {
                  const extracted = await extractImagesFromZip(currentEntry.file);
                  set(updateFileEntryAtom, {
                    id: fileId,
                    patch: { extractedImages: extracted },
                  });
                } catch {
                  // Non-fatal: fall back to annotated images
                }
              }
            } catch (err) {
              set(updateFileEntryAtom, {
                id: fileId,
                patch: {
                  status: "error",
                  error: err instanceof Error ? err.message : "Failed to fetch results",
                },
              });
            }
            sseUnsubscribers.delete(fileId);
          } else if (data.status === "error") {
            set(updateFileEntryAtom, {
              id: fileId,
              patch: {
                status: "error",
                error: data.message || "Batch processing failed",
              },
            });
            sseUnsubscribers.delete(fileId);
          }
        },
        () => {
          set(updateFileEntryAtom, {
            id: fileId,
            patch: { status: "error", error: "Lost connection to server" },
          });
          sseUnsubscribers.delete(fileId);
        },
      );
      sseUnsubscribers.set(fileId, unsub);
    } catch (err) {
      set(updateFileEntryAtom, {
        id: fileId,
        patch: {
          status: "error",
          error: err instanceof Error ? err.message : "Failed to start batch",
        },
      });
    }
  }
});

// ── Run all idle/error files ──
export const runAllIdleFilesAtom = atom(null, async (get, set) => {
  const entries = get(fileEntriesAtom);
  const runnable = entries.filter((e) => e.status === "idle" || e.status === "error");

  const images = runnable.filter((e) => e.kind === "image");
  const zips = runnable.filter((e) => e.kind === "zip");

  // Fire all images in parallel
  await Promise.allSettled(images.map((entry) => set(runFileAtom, entry.id)));

  // Run zips sequentially
  for (const zip of zips) {
    await set(runFileAtom, zip.id);
  }
});

// ── Reset everything ──
export const resetWorkspaceAtom = atom(null, (_get, set) => {
  // Clean up all SSE subscriptions
  sseUnsubscribers.forEach((unsub) => unsub());
  sseUnsubscribers.clear();

  // Clear UI state
  set(inspectedAnnotationAtom, null);
  set(selectedBatchImageIndexAtom, null);

  // Clear files (revokes all object URLs)
  set(resetAllFilesAtom);
});
