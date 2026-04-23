"use client";

import { useEffect } from "react";
import { useSetAtom } from "jotai";

import { CenterCanvas } from "@/components/workspace/CenterCanvas";
import { LeftPanel } from "@/components/workspace/LeftPanel";
import { RightPanel } from "@/components/workspace/RightPanel";
import { fetchClassesAtom } from "@/lib/atoms";

export function AnalyzeWorkspace() {
  const fetchClasses = useSetAtom(fetchClassesAtom);
  useEffect(() => { fetchClasses(); }, [fetchClasses]);

  return (
    <div
      className="grid h-[calc(100vh-57px)] overflow-hidden"
      style={{
        gridTemplateColumns: "280px 1fr 280px",
        gridTemplateRows: "1fr",
        gridTemplateAreas: `"left canvas right"`,
      }}
    >
      <LeftPanel />
      <CenterCanvas />
      <RightPanel />
    </div>
  );
}
