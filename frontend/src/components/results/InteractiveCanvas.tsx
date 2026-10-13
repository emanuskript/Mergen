"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { Slider } from "@/components/ui/slider";
import { COCOAnnotation, COCOJson } from "@/lib/types/coco";
import {
  drawAnnotationsTransformed,
  hitTestAnnotation,
  HandleType,
  hitTestVertex,
  drawVertexHandles,
  applyHandleDrag,
  applyVertexDrag,
  bboxFromSegmentation,
  handleCursor,
  isVertexHandle,
} from "@/lib/utils/annotations";

interface InteractiveCanvasProps {
  imageSrc: string;
  cocoJson: COCOJson;
  colorMap: Map<string, string>;
  selectedClasses: Set<string>;
  onAnnotationClick?: (ann: COCOAnnotation | null) => void;
  selectedAnnotationId?: number | null;
  editingAnnotationId?: number | null;
  onBboxChange?: (annotationId: number, bbox: [number, number, number, number]) => void;
  onSegmentationChange?: (annotationId: number, segmentation: number[][], bbox: [number, number, number, number]) => void;
}

interface Transform {
  scale: number;
  offsetX: number;
  offsetY: number;
}

function computeFit(cw: number, ch: number, imgW: number, imgH: number): Transform {
  const scale = Math.min(cw / imgW, ch / imgH, 1);
  return {
    scale,
    offsetX: (cw - imgW * scale) / 2,
    offsetY: (ch - imgH * scale) / 2,
  };
}

/** Point-in-polygon check for segmentation hit testing */
function pointInPolygonCheck(px: number, py: number, polygon: number[]): boolean {
  let inside = false;
  const n = polygon.length / 2;
  for (let i = 0, j = n - 1; i < n; j = i++) {
    const xi = polygon[i * 2];
    const yi = polygon[i * 2 + 1];
    const xj = polygon[j * 2];
    const yj = polygon[j * 2 + 1];
    if (yi > py !== yj > py && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

export function InteractiveCanvas({
  imageSrc,
  cocoJson,
  colorMap,
  selectedClasses,
  onAnnotationClick,
  selectedAnnotationId,
  editingAnnotationId,
  onBboxChange,
  onSegmentationChange,
}: InteractiveCanvasProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const tRef = useRef<Transform>({ scale: 1, offsetX: 0, offsetY: 0 });
  const fitToViewRef = useRef<() => void>(() => {});
  const redrawRef = useRef<(highlightId?: number | null) => void>(() => {});

  const [opacity, setOpacity] = useState(0.25);
  const hoveredIdRef = useRef<number | null>(null);
  const [tooltip, setTooltip] = useState<{
    x: number;
    y: number;
    className: string;
    area: number;
    bbox: [number, number, number, number];
  } | null>(null);
  const [zoomDisplay, setZoomDisplay] = useState(100);
  const [cursorStyle, setCursorStyle] = useState("");

  // Pan tracking (dragged distinguishes click from drag)
  const panRef = useRef({ active: false, dragged: false, startX: 0, startY: 0, origOX: 0, origOY: 0 });

  // Edit drag tracking
  const editDragRef = useRef<{
    handle: HandleType;
    startImageX: number;
    startImageY: number;
    originalBbox: [number, number, number, number];
    originalSegmentation?: number[][];
    annotationId: number;
  } | null>(null);

  const catById = useRef(new Map<number, string>());

  const getImgSize = useCallback(() => {
    const imgW = cocoJson.images[0]?.width ?? imgRef.current?.naturalWidth ?? 1;
    const imgH = cocoJson.images[0]?.height ?? imgRef.current?.naturalHeight ?? 1;
    return { imgW, imgH };
  }, [cocoJson]);

  // Find editing annotation from cocoJson
  const getEditingAnnotation = useCallback((): COCOAnnotation | null => {
    if (editingAnnotationId == null) return null;
    return cocoJson.annotations.find((a) => a.id === editingAnnotationId) ?? null;
  }, [cocoJson, editingAnnotationId]);

  // ── Draw ──
  const redraw = useCallback(
    (highlightId: number | null = null) => {
      const canvas = canvasRef.current;
      const container = containerRef.current;
      const img = imgRef.current;
      if (!canvas || !container || !img) return;

      const ctx = canvas.getContext("2d");
      if (!ctx) return;

      const dpr = window.devicePixelRatio || 1;
      const { width: cw, height: ch } = container.getBoundingClientRect();

      canvas.width = cw * dpr;
      canvas.height = ch * dpr;
      canvas.style.width = `${cw}px`;
      canvas.style.height = `${ch}px`;

      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, cw, ch);

      const t = tRef.current;
      drawAnnotationsTransformed(
        ctx,
        img,
        cocoJson.annotations,
        cocoJson.categories,
        colorMap,
        selectedClasses,
        t.scale,
        t.offsetX,
        t.offsetY,
        cocoJson.images[0],
        {
          fillOpacity: opacity,
          highlightedId: highlightId,
          selectedId: selectedAnnotationId,
          editingId: editingAnnotationId,
        },
      );

      // Draw edit handles for the editing annotation
      const editAnn = cocoJson.annotations.find(
        (a) => a.id === editingAnnotationId,
      );
      if (editAnn) {
        ctx.save();
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.translate(t.offsetX, t.offsetY);
        ctx.scale(t.scale, t.scale);
        // Only draw polygon vertex handles (no bbox handles)
        if (editAnn.segmentation && editAnn.segmentation.length > 0) {
          drawVertexHandles(ctx, editAnn.segmentation, t.scale);
        }
        ctx.restore();
      }
    },
    [cocoJson, colorMap, selectedClasses, opacity, selectedAnnotationId, editingAnnotationId],
  );

  // ── Fit to view ──
  const fitToView = useCallback(() => {
    const container = containerRef.current;
    if (!container || !imgRef.current) return;
    const { width: cw, height: ch } = container.getBoundingClientRect();
    const { imgW, imgH } = getImgSize();
    tRef.current = computeFit(cw, ch, imgW, imgH);
    setZoomDisplay(Math.round(tRef.current.scale * 100));
    redraw(hoveredIdRef.current);
  }, [getImgSize, redraw]);

  // Keep refs in sync (avoids stale closures without re-running effects)
  useEffect(() => { redrawRef.current = redraw; }, [redraw]);
  useEffect(() => { fitToViewRef.current = fitToView; }, [fitToView]);

  // ── Load image (only when the actual image source changes) ──
  useEffect(() => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => {
      imgRef.current = img;
      const container = containerRef.current;
      if (container) {
        const imgW = img.naturalWidth;
        const imgH = img.naturalHeight;
        const { width: cw, height: ch } = container.getBoundingClientRect();
        tRef.current = computeFit(cw, ch, imgW, imgH);
        setZoomDisplay(Math.round(tRef.current.scale * 100));
      }
      redrawRef.current();
    };
    img.src = imageSrc;
  }, [imageSrc]);

  // Update category map when cocoJson changes (don't reload image)
  useEffect(() => {
    catById.current = new Map(cocoJson.categories.map((c) => [c.id, c.name]));
  }, [cocoJson.categories]);

  // Redraw on filter / opacity / editing changes
  useEffect(() => {
    redraw(hoveredIdRef.current);
  }, [selectedClasses, opacity, redraw]);

  // Resize observer (stable — uses ref so it doesn't re-mount on data changes)
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const ro = new ResizeObserver(() => {
      if (!editDragRef.current) {
        fitToViewRef.current();
      }
    });
    ro.observe(container);
    return () => ro.disconnect();
  }, []);

  // ── Screen → image coords ──
  const screenToImage = useCallback(
    (clientX: number, clientY: number) => {
      const canvas = canvasRef.current;
      if (!canvas) return null;
      const rect = canvas.getBoundingClientRect();
      const sx = clientX - rect.left;
      const sy = clientY - rect.top;
      const t = tRef.current;
      return {
        x: (sx - t.offsetX) / t.scale,
        y: (sy - t.offsetY) / t.scale,
        clientX,
        clientY,
      };
    },
    [],
  );

  // ── Wheel zoom (centered on cursor) ──
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const onWheel = (e: WheelEvent) => {
      // Don't zoom while dragging a vertex or handle
      if (editDragRef.current) return;
      
      e.preventDefault();
      const rect = container.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;

      const t = tRef.current;
      const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
      const newScale = Math.min(Math.max(t.scale * factor, 0.05), 30);

      tRef.current = {
        scale: newScale,
        offsetX: mx - (mx - t.offsetX) * (newScale / t.scale),
        offsetY: my - (my - t.offsetY) * (newScale / t.scale),
      };
      setZoomDisplay(Math.round(newScale * 100));
      redraw(hoveredIdRef.current);
    };

    container.addEventListener("wheel", onWheel, { passive: false });
    return () => container.removeEventListener("wheel", onWheel);
  }, [redraw]);

  // ── Mouse handlers ──
  const DRAG_THRESHOLD = 4; // px — below this it's a click, above it's a drag

  const handleMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0 && e.button !== 1) return;
    e.preventDefault();

    // Middle-click always pans (even while editing)
    if (e.button === 1) {
      panRef.current = {
        active: true,
        dragged: false,
        startX: e.clientX,
        startY: e.clientY,
        origOX: tRef.current.offsetX,
        origOY: tRef.current.offsetY,
      };
      return;
    }

    // If editing, check if clicking a vertex handle, bbox handle, or inside the annotation
    if (editingAnnotationId != null && e.button === 0) {
      const editAnn = getEditingAnnotation();
      if (editAnn) {
        const coords = screenToImage(e.clientX, e.clientY);
        if (coords) {
          // 1. Check vertex handles first (polygon points)
          if (editAnn.segmentation && editAnn.segmentation.length > 0) {
            const vertexHandle = hitTestVertex(
              coords.x,
              coords.y,
              editAnn.segmentation,
              tRef.current.scale,
            );
            if (vertexHandle) {
              editDragRef.current = {
                handle: vertexHandle,
                startImageX: coords.x,
                startImageY: coords.y,
                originalBbox: [...editAnn.bbox],
                originalSegmentation: editAnn.segmentation.map((s) => [...s]),
                annotationId: editAnn.id,
              };
              return;
            }
          }

          // 2. Check if inside the annotation (segmentation or bbox) for move
          let insideAnnotation = false;
          if (editAnn.segmentation && editAnn.segmentation.length > 0) {
            for (const seg of editAnn.segmentation) {
              if (pointInPolygonCheck(coords.x, coords.y, seg)) {
                insideAnnotation = true;
                break;
              }
            }
          }
          if (!insideAnnotation) {
            const [bx, by, bw, bh] = editAnn.bbox;
            if (
              coords.x >= bx &&
              coords.x <= bx + bw &&
              coords.y >= by &&
              coords.y <= by + bh
            ) {
              insideAnnotation = true;
            }
          }

          if (insideAnnotation) {
            editDragRef.current = {
              handle: "move",
              startImageX: coords.x,
              startImageY: coords.y,
              originalBbox: [...editAnn.bbox],
              originalSegmentation: editAnn.segmentation?.map((s) => [...s]),
              annotationId: editAnn.id,
            };
            return;
          }
          // If we're editing but clicked outside the annotation, allow pan
          // (don't return here, fall through to pan logic below)
        }
      }
    }

    // Default: start pan (works at any zoom level, including while editing)
    panRef.current = {
      active: true,
      dragged: false,
      startX: e.clientX,
      startY: e.clientY,
      origOX: tRef.current.offsetX,
      origOY: tRef.current.offsetY,
    };
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    // Handle edit drag (bbox handle, vertex, or move)
    const ed = editDragRef.current;
    if (ed) {
      const coords = screenToImage(e.clientX, e.clientY);
      if (!coords) return;
      const deltaX = coords.x - ed.startImageX;
      const deltaY = coords.y - ed.startImageY;

      if (isVertexHandle(ed.handle)) {
        // Dragging a single polygon vertex
        if (ed.originalSegmentation) {
          const newSeg = applyVertexDrag(ed.originalSegmentation, ed.handle, deltaX, deltaY);
          const newBbox = bboxFromSegmentation(newSeg);
          onSegmentationChange?.(ed.annotationId, newSeg, newBbox);
        }
      } else if (ed.handle === "move" && ed.originalSegmentation) {
        // Move the whole annotation (bbox + segmentation)
        const newBbox = applyHandleDrag(ed.originalBbox, ed.handle, deltaX, deltaY);
        const newSeg = ed.originalSegmentation.map((seg) => {
          const moved = new Array(seg.length);
          for (let i = 0; i < seg.length; i += 2) {
            moved[i] = seg[i] + deltaX;
            moved[i + 1] = seg[i + 1] + deltaY;
          }
          return moved;
        });
        onSegmentationChange?.(ed.annotationId, newSeg, newBbox);
      } else {
        // Bbox-only resize/move
        const newBbox = applyHandleDrag(ed.originalBbox, ed.handle, deltaX, deltaY);
        onBboxChange?.(ed.annotationId, newBbox);
      }
      return;
    }

    // Handle pan
    const p = panRef.current;
    if (p.active) {
      const dx = e.clientX - p.startX;
      const dy = e.clientY - p.startY;
      if (!p.dragged && Math.abs(dx) + Math.abs(dy) > DRAG_THRESHOLD) {
        p.dragged = true;
      }
      if (p.dragged) {
        tRef.current = {
          ...tRef.current,
          offsetX: p.origOX + dx,
          offsetY: p.origOY + dy,
        };
        redraw(hoveredIdRef.current);
        setTooltip(null);
        return;
      }
    }

    // Hover detection
    const coords = screenToImage(e.clientX, e.clientY);
    if (!coords) return;

    // If editing, update cursor based on handle hover
    if (editingAnnotationId != null) {
      const editAnn = getEditingAnnotation();
      if (editAnn) {
        // Check vertex handles first
        if (editAnn.segmentation && editAnn.segmentation.length > 0) {
          const vertexHandle = hitTestVertex(
            coords.x,
            coords.y,
            editAnn.segmentation,
            tRef.current.scale,
          );
          if (vertexHandle) {
            setCursorStyle(handleCursor(vertexHandle));
            setTooltip(null);
            return;
          }
        }
        // Inside annotation (segmentation or bbox) = move cursor
        let insideAnnotation = false;
        if (editAnn.segmentation && editAnn.segmentation.length > 0) {
          for (const seg of editAnn.segmentation) {
            if (pointInPolygonCheck(coords.x, coords.y, seg)) {
              insideAnnotation = true;
              break;
            }
          }
        }
        if (!insideAnnotation) {
          const [bx, by, bw, bh] = editAnn.bbox;
          if (
            coords.x >= bx &&
            coords.x <= bx + bw &&
            coords.y >= by &&
            coords.y <= by + bh
          ) {
            insideAnnotation = true;
          }
        }
        if (insideAnnotation) {
          setCursorStyle("move");
          setTooltip(null);
          return;
        }
      }
      setCursorStyle("");
    } else {
      setCursorStyle("");
    }

    const ann = hitTestAnnotation(
      coords.x,
      coords.y,
      cocoJson.annotations,
      cocoJson.categories,
      selectedClasses,
    );

    if (ann) {
      if (hoveredIdRef.current !== ann.id) {
        hoveredIdRef.current = ann.id;
        redraw(ann.id);
      }
      setTooltip({
        x: coords.clientX,
        y: coords.clientY,
        className: catById.current.get(ann.category_id) || "Unknown",
        area: Math.round(ann.area),
        bbox: ann.bbox,
      });
    } else {
      if (hoveredIdRef.current !== null) {
        hoveredIdRef.current = null;
        redraw(null);
      }
      setTooltip(null);
    }
  };

  const handleMouseUp = (e: React.MouseEvent) => {
    // Finalize edit drag
    if (editDragRef.current) {
      editDragRef.current = null;
      return;
    }

    const p = panRef.current;
    const wasDrag = p.dragged;
    panRef.current = { ...p, active: false, dragged: false };

    // If it wasn't a drag, treat as a click for annotation selection
    if (!wasDrag && e.button === 0) {
      const coords = screenToImage(e.clientX, e.clientY);
      if (!coords) return;
      const ann = hitTestAnnotation(
        coords.x,
        coords.y,
        cocoJson.annotations,
        cocoJson.categories,
        selectedClasses,
      );
      onAnnotationClick?.(ann);
    }
  };

  const handleMouseLeave = () => {
    panRef.current = { ...panRef.current, active: false, dragged: false };
    editDragRef.current = null;
    if (hoveredIdRef.current !== null) {
      hoveredIdRef.current = null;
      redraw(null);
    }
    setTooltip(null);
    setCursorStyle("");
  };

  const handleDoubleClick = () => fitToView();

  const canvasCursor = cursorStyle || (editingAnnotationId != null ? "default" : "");

  return (
    <div ref={containerRef} className="relative h-full w-full overflow-hidden">
      <canvas
        ref={canvasRef}
        className={`absolute inset-0 ${canvasCursor ? "" : "cursor-grab active:cursor-grabbing"}`}
        style={canvasCursor ? { cursor: canvasCursor } : undefined}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseLeave}
        onDoubleClick={handleDoubleClick}
      />

      {/* Floating controls */}
      <div className="absolute bottom-3 left-3 flex items-center gap-3 rounded-lg border bg-card/90 px-3 py-1.5 shadow-sm backdrop-blur-sm">
        <span className="text-xs font-medium text-muted-foreground">Opacity</span>
        <Slider
          className="w-24"
          min={0}
          max={1}
          step={0.05}
          value={[opacity]}
          onValueChange={([v]) => setOpacity(v)}
        />
        <span className="w-8 text-xs text-muted-foreground">{Math.round(opacity * 100)}%</span>
        <span className="border-l pl-3 text-xs text-muted-foreground">{zoomDisplay}%</span>
        <button
          onClick={fitToView}
          className="rounded px-1.5 py-0.5 text-xs text-muted-foreground hover:bg-muted hover:text-foreground"
          title="Fit to view (or double-click)"
        >
          Fit
        </button>
      </div>

      {/* Hover tooltip */}
      {tooltip && (
        <div
          className="pointer-events-none fixed z-50 rounded-md border bg-popover px-3 py-2 text-xs shadow-lg"
          style={{ left: tooltip.x + 12, top: tooltip.y + 12 }}
        >
          <p className="font-semibold">{tooltip.className}</p>
          <p className="text-muted-foreground">
            Area: {tooltip.area.toLocaleString()} px&sup2;
          </p>
          <p className="text-muted-foreground">
            BBox: {Math.round(tooltip.bbox[2])}&times;{Math.round(tooltip.bbox[3])}
          </p>
        </div>
      )}
    </div>
  );
}
