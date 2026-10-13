"use client";

import { createElement, useEffect, useRef, useState } from "react";
import { useAtomValue } from "jotai";
import * as LucideIcons from "lucide-react";
import { tourStepIndexAtom, tourTotalStepsAtom } from "@/lib/atoms";
import type { TourStep } from "@/data/tourSteps";
import { TourProgress } from "./TourProgress";
import { TourNavigation } from "./TourNavigation";
import { cn } from "@/lib/utils";

interface TargetRect {
  top: number;
  left: number;
  width: number;
  height: number;
  bottom: number;
  right: number;
}

interface TourTooltipProps {
  step: TourStep;
  targetRect: TargetRect | null;
}

type ArrowDirection = "top" | "bottom" | "left" | "right" | "none";

function getIcon(name: string): LucideIcons.LucideIcon | null {
  const pascal = name
    .split("-")
    .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
    .join("");
  return (
    (LucideIcons as unknown as Record<string, LucideIcons.LucideIcon>)[pascal] ?? null
  );
}

const arrowClasses: Record<Exclude<ArrowDirection, "none">, string> = {
  top: "-top-1.5 left-1/2 -ml-1.5 border-b-0 border-r-0",
  bottom: "-bottom-1.5 left-1/2 -ml-1.5 border-t-0 border-l-0",
  left: "-left-1.5 top-1/2 -mt-1.5 border-t-0 border-r-0",
  right: "-right-1.5 top-1/2 -mt-1.5 border-b-0 border-l-0",
};

export function TourTooltip({ step, targetRect }: TourTooltipProps) {
  const currentIndex = useAtomValue(tourStepIndexAtom);
  const totalSteps = useAtomValue(tourTotalStepsAtom);

  const tooltipRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ top: 0, left: 0 });
  const [arrow, setArrow] = useState<ArrowDirection>("none");

  const icon = getIcon(step.icon);

  useEffect(() => {
    const tooltip = tooltipRef.current;
    if (!tooltip) return;

    // Wait one frame for the tooltip to render so we can measure it
    const raf = requestAnimationFrame(() => {
      const tooltipRect = tooltip.getBoundingClientRect();
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const pad = 16;
      const offset = 12;

      const placement = step.placement;

      // Center in viewport for steps without target
      if (!targetRect || placement === "center") {
        setPosition({
          top: (vh - tooltipRect.height) / 2,
          left: (vw - tooltipRect.width) / 2,
        });
        setArrow("none");
        return;
      }

      const target = targetRect;

      const positions = {
        top: {
          top: target.top - tooltipRect.height - offset,
          left: target.left + (target.width - tooltipRect.width) / 2,
          arrow: "bottom" as ArrowDirection,
        },
        bottom: {
          top: target.bottom + offset,
          left: target.left + (target.width - tooltipRect.width) / 2,
          arrow: "top" as ArrowDirection,
        },
        left: {
          top: target.top + (target.height - tooltipRect.height) / 2,
          left: target.left - tooltipRect.width - offset,
          arrow: "right" as ArrowDirection,
        },
        right: {
          top: target.top + (target.height - tooltipRect.height) / 2,
          left: target.right + offset,
          arrow: "left" as ArrowDirection,
        },
      };

      const fits = (p: { top: number; left: number }) =>
        p.top >= pad &&
        p.left >= pad &&
        p.top + tooltipRect.height <= vh - pad &&
        p.left + tooltipRect.width <= vw - pad;

      let pos = positions[placement as keyof typeof positions] ?? positions.bottom;

      if (!fits(pos)) {
        // Try opposite
        const opposites: Record<string, string> = {
          top: "bottom",
          bottom: "top",
          left: "right",
          right: "left",
        };
        const opposite = positions[opposites[placement] as keyof typeof positions];
        if (opposite && fits(opposite)) {
          pos = opposite;
        } else {
          // Try all placements
          for (const value of Object.values(positions)) {
            if (fits(value)) {
              pos = value;
              break;
            }
          }
        }
      }

      // Clamp to viewport
      const top = Math.max(pad, Math.min(pos.top, vh - tooltipRect.height - pad));
      const left = Math.max(pad, Math.min(pos.left, vw - tooltipRect.width - pad));

      setPosition({ top, left });
      setArrow(pos.arrow);
    });

    return () => cancelAnimationFrame(raf);
  }, [step, targetRect]);

  return (
    <div
      ref={tooltipRef}
      className="fixed z-[10000] w-[340px] max-w-[calc(100vw-2rem)] rounded-xl border bg-card shadow-xl pointer-events-auto animate-in fade-in slide-in-from-bottom-2 duration-200"
      style={{ top: `${position.top}px`, left: `${position.left}px` }}
    >
      {/* Arrow */}
      {arrow !== "none" && (
        <div
          className={cn(
            "absolute h-3 w-3 rotate-45 border bg-card",
            arrowClasses[arrow],
          )}
        />
      )}

      {/* Header */}
      <div className="flex items-center gap-2 px-4 pt-4 pb-2">
        {icon && (
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
            {createElement(icon, { className: "h-5 w-5" })}
          </div>
        )}
        <h3 className="flex-1 text-base font-semibold text-foreground">
          {step.title}
        </h3>
        <span className="text-xs font-medium text-muted-foreground">
          {currentIndex + 1}/{totalSteps}
        </span>
      </div>

      {/* Content */}
      <div className="px-4 py-3">
        <p className="text-sm leading-relaxed text-foreground">{step.content}</p>
        {step.tip && (
          <div className="mt-3 flex items-start gap-2 rounded-md bg-muted p-2 text-[13px] text-muted-foreground">
            <LucideIcons.Lightbulb className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary" />
            <span>{step.tip}</span>
          </div>
        )}
      </div>

      {/* Progress + Navigation */}
      <TourProgress />
      <TourNavigation />
    </div>
  );
}
