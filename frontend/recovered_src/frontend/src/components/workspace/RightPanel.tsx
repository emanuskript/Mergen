"use client";

import { useMemo, useState } from "react";
import { useAtomValue, useSetAtom } from "jotai";

import { ClassFilterSidebar } from "@/components/analysis/ClassFilterSidebar";
import { AnnotationInspector } from "@/components/results/AnnotationInspector";
import { ChartModal } from "@/components/results/ChartModal";
import { MiniBarChart } from "@/components/results/MiniBarChart";
import { StatsTable } from "@/components/results/StatsTable";
import {
  classesAtom,
  selectedClassNamesAtom,
  toggleClassAtom,
  selectAllClassesAtom,
  unselectAllClassesAtom,
  colorMapAtom,
  selectedFileAtom,
  inspectedAnnotationAtom,
  chartModalOpenAtom,
  editingAnnotationIdAtom,
  resetAnnotationEditAtom,
  annotationEditsAtom,
  effectiveCocoJsonAtom,
} from "@/lib/atoms";

type TabId = "filter" | "results" | "inspector";

export function RightPanel() {
  const classes = useAtomValue(classesAtom);
  const selected = useAtomValue(selectedClassNamesAtom);
  const toggleClass = useSetAtom(toggleClassAtom);
  const selectAll = useSetAtom(selectAllClassesAtom);
  const unselectAll = useSetAtom(unselectAllClassesAtom);
  const colorMap = useAtomValue(colorMapAtom);
  const selectedFile = useAtomValue(selectedFileAtom);
  const inspectedAnnotation = useAtomValue(inspectedAnnotationAtom);
  const setInspectedAnnotation = useSetAtom(inspectedAnnotationAtom);
  const setChartModalOpen = useSetAtom(chartModalOpenAtom);
  const editingAnnotationId = useAtomValue(editingAnnotationIdAtom);
  const setEditingAnnotationId = useSetAtom(editingAnnotationIdAtom);
  const resetAnnotationEdit = useSetAtom(resetAnnotationEditAtom);
  const annotationEdits = useAtomValue(annotationEditsAtom);
  const effectiveCocoJson = useAtomValue(effectiveCocoJsonAtom);

  const [activeTab, setActiveTab] = useState<TabId>("filter");

  // Derive stats from selected file
  const stats =
    selectedFile?.singleResult?.stats ??
    selectedFile?.batchResults?.stats_summary ??
    null;

  const categories = effectiveCocoJson?.categories ?? selectedFile?.singleResult?.coco_json?.categories ?? [];
  const imageInfo = effectiveCocoJson?.images?.[0] ?? selectedFile?.singleResult?.coco_json?.images?.[0];

  // Get the effective annotation (with edits applied)
  const effectiveAnnotation = useMemo(() => {
    if (!inspectedAnnotation) return null;
    const effective = effectiveCocoJson?.annotations.find(
      (a) => a.id === inspectedAnnotation.id,
    );
    return effective ?? inspectedAnnotation;
  }, [inspectedAnnotation, effectiveCocoJson]);

  const isEditing = editingAnnotationId != null && editingAnnotationId === inspectedAnnotation?.id;
  const currentAnnotationHasEdits = !!(
    selectedFile &&
    inspectedAnnotation &&
    annotationEdits.get(selectedFile.id)?.has(inspectedAnnotation.id)
  );

  // Auto-switch to inspector when annotation is clicked
  const currentTab = inspectedAnnotation ? "inspector" : activeTab;

  const tabs: { id: TabId; label: string; disabled: boolean }[] = [
    { id: "filter", label: "Filter", disabled: false },
    { id: "results", label: "Results", disabled: !stats },
    { id: "inspector", label: "Details", disabled: !inspectedAnnotation },
  ];

  return (
    <aside
      style={{ gridArea: "right" }}
      className="flex flex-col overflow-hidden border-l bg-background"
    >
      {/* Tabs */}
      <div className="flex h-10 items-center border-b">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            data-tour={
              tab.id === "filter"
                ? "class-filter"
                : tab.id === "results"
                  ? "results-tab"
                  : "inspector-tab"
            }
            onClick={() => {
              if (!tab.disabled) {
                setActiveTab(tab.id);
                if (tab.id !== "inspector") {
                  setEditingAnnotationId(null);
                  setInspectedAnnotation(null);
                }
              }
            }}
            disabled={tab.disabled}
            className={`flex-1 px-2 py-2 text-xs font-medium transition-colors ${
              currentTab === tab.id
                ? "border-b-2 border-primary text-primary"
                : tab.disabled
                  ? "cursor-not-allowed text-muted-foreground/40"
                  : "text-muted-foreground hover:text-foreground"
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div className="flex-1 overflow-y-auto p-3">
        {currentTab === "filter" && (
          <ClassFilterSidebar
            classes={classes}
            selected={selected}
            onToggle={toggleClass}
            onSelectAll={selectAll}
            onUnselectAll={unselectAll}
          />
        )}
        {currentTab === "results" && stats && (
          <div className="space-y-4">
            <StatsTable stats={stats} colorMap={colorMap} />
            <div>
              <div className="mb-2 flex items-center justify-between">
                <p className="text-xs font-medium text-muted-foreground">Distribution</p>
                <button
                  onClick={() => setChartModalOpen(true)}
                  className="text-xs text-primary hover:text-primary/80"
                >
                  View full chart
                </button>
              </div>
              <MiniBarChart stats={stats} colorMap={colorMap} />
            </div>
          </div>
        )}
        {currentTab === "inspector" && effectiveAnnotation && (
          <AnnotationInspector
            annotation={effectiveAnnotation}
            categories={categories}
            colorMap={colorMap}
            imageInfo={imageInfo}
            onClose={() => {
              setEditingAnnotationId(null);
              setInspectedAnnotation(null);
            }}
            isEditing={isEditing}
            onEdit={() => setEditingAnnotationId(effectiveAnnotation.id)}
            onDoneEditing={() => setEditingAnnotationId(null)}
            onReset={() => {
              if (selectedFile && inspectedAnnotation) {
                resetAnnotationEdit({
                  fileId: selectedFile.id,
                  annotationId: inspectedAnnotation.id,
                });
              }
            }}
            hasEdits={currentAnnotationHasEdits}
          />
        )}
      </div>

      {/* Chart modal */}
      <ChartModal />
    </aside>
  );
}
