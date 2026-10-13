"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useAtomValue, useSetAtom } from "jotai";
import {
  currentTourStepAtom,
  skipTourAtom,
  nextTourStepAtom,
  prevTourStepAtom,
  tourIsFirstStepAtom,
  tourIsLastStepAtom,
} from "@/lib/atoms";
import { TourTooltip } from "./TourTooltip";

interface TargetRect {
  top: number;
  left: number;
  width: number;
  height: number;
  bottom: number;
  right: number;
}

export function TourSpotlight() {
  const step = useAtomValue(currentTourStepAtom);
  const skip = useSetAtom(skipTourAtom);
  const next = useSetAtom(nextTourStepAtom);
  const prev = useSetAtom(prevTourStepAtom);
  const isFirst = useAtomValue(tourIsFirstStepAtom);
  const isLast = useAtomValue(tourIsLastStepAtom);

  const [targetRect, setTargetRect] = useState<TargetRect | null>(null);
  const [isPositioned, setIsPositioned] = useState(false);
  const spotlightRef = useRef<HTMLDivElement>(null);

  const updateTargetPosition = useCallback(() => {
    if (!step) return;

    if (!step.target) {
      setTargetRect(null);
      setIsPositioned(true);
      return;
    }

    const element = document.querySelector(step.target);
    if (!element) {
      setTargetRect(null);
      setIsPositioned(true);
      return;
    }

    const rect = element.getBoundingClientRect();
    setTargetRect({
      top: rect.top,
      left: rect.left,
      width: rect.width,
      height: rect.height,
      bottom: rect.bottom,
      right: rect.right,
    });

    if (step.target) {
      element.scrollIntoView({
        behavior: "smooth",
        block: "center",
        inline: "center",
      });
    }

    setIsPositioned(true);
  }, [step]);

  // Recalculate on step change
  useEffect(() => {
    const resetFrame = requestAnimationFrame(() => setIsPositioned(false));
    // Small delay to let DOM settle after step change
    const timer = setTimeout(updateTargetPosition, 50);
    return () => {
      cancelAnimationFrame(resetFrame);
      clearTimeout(timer);
    };
  }, [step, updateTargetPosition]);

  // Listen for resize/scroll
  useEffect(() => {
    window.addEventListener("resize", updateTargetPosition);
    window.addEventListener("scroll", updateTargetPosition, true);

    let observer: ResizeObserver | null = null;
    if (typeof ResizeObserver !== "undefined") {
      observer = new ResizeObserver(updateTargetPosition);
      observer.observe(document.body);
    }

    return () => {
      window.removeEventListener("resize", updateTargetPosition);
      window.removeEventListener("scroll", updateTargetPosition, true);
      observer?.disconnect();
    };
  }, [updateTargetPosition]);

  // Keyboard navigation
  useEffect(() => {
    function handleKeydown(e: KeyboardEvent) {
      switch (e.key) {
        case "Escape":
          skip();
          break;
        case "ArrowRight":
          if (!isLast) next();
          break;
        case "ArrowLeft":
          if (!isFirst) prev();
          break;
      }
    }

    document.addEventListener("keydown", handleKeydown);
    return () => document.removeEventListener("keydown", handleKeydown);
  }, [skip, next, prev, isFirst, isLast]);

  if (!step) return null;

  const padding = step.spotlightPadding ?? 8;
  const radius = step.spotlightRadius ?? 8;

  const clipPath =
    targetRect
      ? `polygon(
          0% 0%, 0% 100%,
          ${targetRect.left - padding}px 100%,
          ${targetRect.left - padding}px ${targetRect.top - padding}px,
          ${targetRect.right + padding}px ${targetRect.top - padding}px,
          ${targetRect.right + padding}px ${targetRect.bottom + padding}px,
          ${targetRect.left - padding}px ${targetRect.bottom + padding}px,
          ${targetRect.left - padding}px 100%,
          100% 100%, 100% 0%
        )`
      : "none";

  // Use inset with border-radius for the spotlight hole effect
  // clip-path polygon doesn't support border-radius, so we use a rounded
  // box-shadow approach for the cutout when we have a radius
  const overlayStyle: React.CSSProperties =
    targetRect && radius > 0
      ? {
          // For rounded cutouts, use a massive box-shadow to create the overlay
          // and position a transparent rounded box at the target
          background: "transparent",
          boxShadow: `0 0 0 9999px rgba(0, 0, 0, 0.75)`,
          borderRadius: `${radius}px`,
          position: "fixed" as const,
          top: `${targetRect.top - padding}px`,
          left: `${targetRect.left - padding}px`,
          width: `${targetRect.width + padding * 2}px`,
          height: `${targetRect.height + padding * 2}px`,
          zIndex: 9999,
          pointerEvents: "none" as const,
          transition: "all 0.3s ease",
        }
      : {
          position: "absolute" as const,
          inset: 0,
          background: "rgba(0, 0, 0, 0.75)",
          clipPath,
          transition: "clip-path 0.3s ease",
          pointerEvents: "auto" as const,
        };

  const overlay = (
    <div
      ref={spotlightRef}
      className="fixed inset-0 z-[9999]"
      role="dialog"
      aria-modal="true"
      aria-label={`Tour step: ${step.title}`}
    >
      {/* Overlay with cutout */}
      {targetRect && radius > 0 ? (
        <>
          {/* Click-blocking overlay behind the cutout */}
          <div
            className="absolute inset-0"
            style={{ pointerEvents: "auto" }}
            onClick={(e) => e.stopPropagation()}
          />
          {/* Rounded cutout via box-shadow */}
          <div style={overlayStyle} />
        </>
      ) : (
        <div style={overlayStyle} />
      )}

      {/* Tooltip */}
      {isPositioned && (
        <TourTooltip step={step} targetRect={targetRect} />
      )}

      {/* Screen reader announcement */}
      <div className="sr-only" aria-live="polite" aria-atomic="true">
        {`Step: ${step.title}. ${step.content}`}
      </div>
    </div>
  );

  if (typeof document === "undefined") return null;

  return createPortal(overlay, document.body);
}
