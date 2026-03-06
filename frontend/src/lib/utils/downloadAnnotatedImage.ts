import { COCOJson } from "../types/coco";
import { drawAnnotations } from "./annotations";

/**
 * Render the image with all visible annotations at full resolution
 * and trigger a high-quality JPEG download.
 */
export function downloadAnnotatedImage(
  imageSrc: string,
  cocoJson: COCOJson,
  colorMap: Map<string, string>,
  selectedClasses: Set<string>,
  filename = "annotated_image.jpg",
): void {
  const LEGEND_SIZE_MULTIPLIER = 5;
  const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));

  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => {
    const annotatedCanvas = document.createElement("canvas");
    const annotatedCtx = annotatedCanvas.getContext("2d");
    if (!annotatedCtx) return;

    // Draw at full image resolution with annotations
    drawAnnotations(annotatedCtx, img, cocoJson.annotations, cocoJson.categories, colorMap, selectedClasses, cocoJson.images[0], {
      fillOpacity: 0.25,
      strokeOpacity: 0.8,
      showLabels: true,
    });

    const categoryNameById = new Map(cocoJson.categories.map((category) => [category.id, category.name]));
    const presentClasses = new Set<string>();

    for (const annotation of cocoJson.annotations) {
      const className = categoryNameById.get(annotation.category_id);
      if (!className || !selectedClasses.has(className)) continue;
      presentClasses.add(className);
    }

    const legendItems = cocoJson.categories
      .map((category) => category.name)
      .filter((className) => presentClasses.has(className));

    const exportCanvas = document.createElement("canvas");
    const exportCtx = exportCanvas.getContext("2d");
    if (!exportCtx) return;

    exportCanvas.width = annotatedCanvas.width;
    exportCanvas.height = annotatedCanvas.height;
    exportCtx.drawImage(annotatedCanvas, 0, 0);

    if (legendItems.length > 0) {
      const horizontalPadding = clamp(24 * LEGEND_SIZE_MULTIPLIER, 12, 48);
      const verticalPadding = clamp(18 * LEGEND_SIZE_MULTIPLIER, 10, 36);
      const headingGap = clamp(12 * LEGEND_SIZE_MULTIPLIER, 6, 20);
      const rowGap = clamp(10 * LEGEND_SIZE_MULTIPLIER, 4, 16);
      const itemGap = clamp(24 * LEGEND_SIZE_MULTIPLIER, 10, 28);
      const swatchSize = clamp(20 * LEGEND_SIZE_MULTIPLIER, 10, 30);
      const textGap = clamp(10 * LEGEND_SIZE_MULTIPLIER, 6, 16);
      const headingSize = clamp(22 * LEGEND_SIZE_MULTIPLIER, 14, 40);
      const labelSize = clamp(18 * LEGEND_SIZE_MULTIPLIER, 12, 32);
      const rowHeight = Math.max(swatchSize, labelSize) + 8;
      const outerMargin = clamp(12 * LEGEND_SIZE_MULTIPLIER, 8, 24);
      const maxLegendWidth = Math.max(Math.min(exportCanvas.width * 0.5, exportCanvas.width - outerMargin * 2), 180);
      const maxRowWidth = Math.max(maxLegendWidth - horizontalPadding * 2, 120);

      const rows: string[][] = [];
      const rowWidths: number[] = [];
      let currentRow: string[] = [];
      let currentRowWidth = 0;

      exportCtx.font = `600 ${labelSize}px sans-serif`;
      for (const className of legendItems) {
        const labelWidth = exportCtx.measureText(className).width;
        const itemWidth = swatchSize + textGap + labelWidth + itemGap;

        if (currentRow.length > 0 && currentRowWidth + itemWidth > maxRowWidth) {
          rows.push(currentRow);
          rowWidths.push(currentRowWidth);
          currentRow = [className];
          currentRowWidth = itemWidth;
        } else {
          currentRow.push(className);
          currentRowWidth += itemWidth;
        }
      }
      if (currentRow.length > 0) {
        rows.push(currentRow);
        rowWidths.push(currentRowWidth);
      }

      const widestRow = rowWidths.length ? Math.max(...rowWidths) : 0;
      const legendWidth = Math.min(maxLegendWidth, widestRow + horizontalPadding * 2);
      const legendHeight =
        verticalPadding * 2 +
        headingSize +
        headingGap +
        rows.length * rowHeight +
        Math.max(0, rows.length - 1) * rowGap;

      const legendX = exportCanvas.width - legendWidth - outerMargin;
      const legendY = exportCanvas.height - legendHeight - outerMargin;

      exportCtx.fillStyle = "rgba(255,255,255,0.9)";
      exportCtx.fillRect(legendX, legendY, legendWidth, legendHeight);
      exportCtx.strokeStyle = "rgba(31,41,55,0.55)";
      exportCtx.lineWidth = 1.5;
      exportCtx.strokeRect(legendX, legendY, legendWidth, legendHeight);

      exportCtx.fillStyle = "#111827";
      exportCtx.font = `700 ${headingSize}px sans-serif`;
      exportCtx.textBaseline = "top";
      exportCtx.fillText("Legend", legendX + horizontalPadding, legendY + verticalPadding);

      let y = legendY + verticalPadding + headingSize + headingGap;
      exportCtx.font = `600 ${labelSize}px sans-serif`;
      exportCtx.textBaseline = "middle";

      for (const row of rows) {
        let x = legendX + horizontalPadding;
        for (const className of row) {
          const labelWidth = exportCtx.measureText(className).width;
          const color = colorMap.get(className) ?? "#888888";

          const swatchY = y + Math.floor((rowHeight - swatchSize) / 2);
          exportCtx.fillStyle = color;
          exportCtx.fillRect(x, swatchY, swatchSize, swatchSize);
          exportCtx.strokeStyle = "#374151";
          exportCtx.lineWidth = 1;
          exportCtx.strokeRect(x, swatchY, swatchSize, swatchSize);

          exportCtx.fillStyle = "#111827";
          exportCtx.fillText(className, x + swatchSize + textGap, y + rowHeight / 2);

          x += swatchSize + textGap + labelWidth + itemGap;
        }
        y += rowHeight + rowGap;
      }
    }

    // Export as highest quality JPEG
    exportCanvas.toBlob(
      (blob) => {
        if (!blob) return;
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = filename;
        a.click();
        URL.revokeObjectURL(url);
      },
      "image/jpeg",
      0.92,
    );
  };
  img.src = imageSrc;
}
