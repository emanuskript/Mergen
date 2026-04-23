"use client";

import { useRef } from "react";
import { useAtom, useAtomValue, useSetAtom } from "jotai";

import { FileEntryItem } from "@/components/workspace/FileEntryItem";
import {
  fileEntriesAtom,
  selectedFileIdAtom,
  addFilesAtom,
  removeFileAtom,
  updateFileEntryAtom,
  idleFileCountAtom,
  expandedFileIdAtom,
  runFileAtom,
  anyLoadingAtom,
  selectedBatchImageIndexAtom,
} from "@/lib/atoms";

const ACCEPT = ".png,.jpg,.jpeg,.bmp,.tif,.tiff,.webp,.zip";

export function LeftPanel() {
  const entries = useAtomValue(fileEntriesAtom);
  const [selectedId, setSelectedId] = useAtom(selectedFileIdAtom);
  const [expandedId, setExpandedId] = useAtom(expandedFileIdAtom);
  const addFiles = useSetAtom(addFilesAtom);
  const removeFile = useSetAtom(removeFileAtom);
  const updateEntry = useSetAtom(updateFileEntryAtom);
  const runFile = useSetAtom(runFileAtom);
  const idleCount = useAtomValue(idleFileCountAtom);
  const anyLoading = useAtomValue(anyLoadingAtom);
  const [selectedBatchImage, setSelectedBatchImage] = useAtom(selectedBatchImageIndexAtom);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const doneCount = entries.filter((e) => e.status === "done").length;

  const handleFilesSelected = (fileList: FileList | null) => {
    if (!fileList || fileList.length === 0) return;
    addFiles(Array.from(fileList));
  };

  return (
    <aside
      data-tour="left-panel"
      style={{ gridArea: "left" }}
      className="flex flex-col overflow-hidden border-r bg-background"
    >
      {/* File list header */}
      <div className="flex items-center justify-between border-b px-3 py-2">
        <span className="text-xs font-medium text-muted-foreground">
          Files ({entries.length})
        </span>
        <button
          onClick={() => fileInputRef.current?.click()}
          className="flex items-center gap-1 rounded-md px-2 py-1 text-xs font-medium text-primary hover:bg-primary/10"
        >
          <svg className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
          Add
        </button>
        <input
          ref={fileInputRef}
          type="file"
          className="hidden"
          accept={ACCEPT}
          multiple
          onChange={(e) => {
            handleFilesSelected(e.target.files);
            e.target.value = "";
          }}
        />
      </div>

      {/* Scrollable file list */}
      <div className="flex-1 overflow-y-auto">
        {entries.length === 0 ? (
          <div className="flex flex-col items-center justify-center px-4 py-8 text-center text-muted-foreground">
            <svg className="mb-2 h-8 w-8 opacity-30" fill="none" stroke="currentColor" strokeWidth={1.5} viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />
            </svg>
            <p className="text-xs">
              Click &quot;Add&quot; or drop files
              <br />
              to get started
            </p>
          </div>
        ) : (
          entries.map((entry) => (
            <FileEntryItem
              key={entry.id}
              entry={entry}
              isSelected={entry.id === selectedId}
              isExpanded={entry.id === expandedId}
              onSelect={() => setSelectedId(entry.id)}
              onToggleExpand={() =>
                setExpandedId(expandedId === entry.id ? null : entry.id)
              }
              onRemove={() => removeFile(entry.id)}
              onRun={() => runFile(entry.id)}
              onUpdateSettings={(patch) =>
                updateEntry({ id: entry.id, patch })
              }
              selectedBatchImageIndex={
                entry.id === selectedId ? selectedBatchImage : null
              }
              onSelectBatchImage={(idx) => {
                setSelectedId(entry.id);
                setSelectedBatchImage(idx);
              }}
            />
          ))
        )}
      </div>

      {/* Footer: Run all + progress */}
      {entries.length > 0 && (
        <div className="flex items-center justify-between border-t px-3 py-2">
          {idleCount > 0 ? (
            <button
              onClick={() => {
                const runnable = entries.filter(
                  (e) => e.status === "idle" || e.status === "error",
                );
                runnable.forEach((e) => runFile(e.id));
              }}
              disabled={anyLoading}
              className="rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
            >
              Run {idleCount > 1 ? `All (${idleCount})` : ""}
            </button>
          ) : (
            <span />
          )}
          <span className="text-xs text-muted-foreground">
            {doneCount}/{entries.length} done
          </span>
        </div>
      )}
    </aside>
  );
}
