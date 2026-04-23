import { atom } from "jotai";
import { FileEntry, FileEntryKind } from "./types";

// ── Default detection settings (for new files) ──
export const defaultConfidenceAtom = atom(0.25);
export const defaultIouAtom = atom(0.3);

// ── Core file list ──
export const fileEntriesAtom = atom<FileEntry[]>([]);

// ── Selected (active) file id ──
export const selectedFileIdAtom = atom<string | null>(null);

// ── Derived: currently selected FileEntry ──
export const selectedFileAtom = atom<FileEntry | null>((get) => {
  const id = get(selectedFileIdAtom);
  if (!id) return null;
  return get(fileEntriesAtom).find((f) => f.id === id) ?? null;
});

// ── Derived: is anything currently analyzing? ──
export const anyLoadingAtom = atom<boolean>((get) =>
  get(fileEntriesAtom).some((f) => f.status === "analyzing"),
);

// ── Derived: does any file have results? ──
export const anyHasResultsAtom = atom<boolean>((get) =>
  get(fileEntriesAtom).some((f) => f.status === "done"),
);

// ── Derived: total file count ──
export const fileCountAtom = atom<number>((get) => get(fileEntriesAtom).length);

// ── Derived: count of idle/error files (runnable) ──
export const idleFileCountAtom = atom<number>((get) =>
  get(fileEntriesAtom).filter((f) => f.status === "idle" || f.status === "error").length,
);

// ── Write atom: add files ──
export const addFilesAtom = atom(null, (get, set, files: File[]) => {
  const conf = get(defaultConfidenceAtom);
  const iou = get(defaultIouAtom);
  const newEntries: FileEntry[] = files.map((file) => {
    const kind: FileEntryKind = isZip(file) ? "zip" : "image";
    return {
      id: crypto.randomUUID(),
      file,
      kind,
      thumbnailUrl: kind === "image" ? URL.createObjectURL(file) : null,
      confidence: conf,
      iou,
      status: "idle",
      error: null,
      singleResult: null,
      batchProgress: null,
      batchResults: null,
      batchTaskId: null,
      extractedImages: null,
    };
  });
  const current = get(fileEntriesAtom);
  set(fileEntriesAtom, [...current, ...newEntries]);
  // Auto-select the first added file if nothing is selected
  if (!get(selectedFileIdAtom) && newEntries.length > 0) {
    set(selectedFileIdAtom, newEntries[0].id);
  }
});

// ── Write atom: remove a file ──
export const removeFileAtom = atom(null, (get, set, id: string) => {
  const entries = get(fileEntriesAtom);
  const entry = entries.find((e) => e.id === id);
  if (entry?.thumbnailUrl) URL.revokeObjectURL(entry.thumbnailUrl);
  entry?.extractedImages?.forEach((url) => URL.revokeObjectURL(url));
  const next = entries.filter((e) => e.id !== id);
  set(fileEntriesAtom, next);
  if (get(selectedFileIdAtom) === id) {
    set(selectedFileIdAtom, next[0]?.id ?? null);
  }
});

// ── Write atom: update a specific file entry (partial update) ──
export const updateFileEntryAtom = atom(
  null,
  (get, set, payload: { id: string; patch: Partial<FileEntry> }) => {
    set(
      fileEntriesAtom,
      get(fileEntriesAtom).map((e) =>
        e.id === payload.id ? { ...e, ...payload.patch } : e,
      ),
    );
  },
);

// ── Write atom: reset everything ──
export const resetAllFilesAtom = atom(null, (get, set) => {
  const entries = get(fileEntriesAtom);
  entries.forEach((e) => {
    if (e.thumbnailUrl) URL.revokeObjectURL(e.thumbnailUrl);
    e.extractedImages?.forEach((url) => URL.revokeObjectURL(url));
  });
  set(fileEntriesAtom, []);
  set(selectedFileIdAtom, null);
});

function isZip(file: File): boolean {
  return (
    file.type === "application/zip" ||
    file.type === "application/x-zip-compressed" ||
    file.name.toLowerCase().endsWith(".zip")
  );
}
