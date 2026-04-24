"use client";

import { useEffect, useState } from "react";
import { useAtomValue, useSetAtom } from "jotai";
import {
  tourActiveAtom,
  tourHasSeenAtom,
  currentTourStepAtom,
  loadTourState,
} from "@/lib/atoms";
import { TourSpotlight } from "./TourSpotlight";

export function TourProvider({ children }: { children: React.ReactNode }) {
  const tourActive = useAtomValue(tourActiveAtom);
  const currentStep = useAtomValue(currentTourStepAtom);
  const setHasSeen = useSetAtom(tourHasSeenAtom);
  const [isReady, setIsReady] = useState(false);

  // Load persisted tour state on mount
  useEffect(() => {
    const state = loadTourState();
    if (state.hasSeenTour) {
      setHasSeen(true);
    }
    const timer = setTimeout(() => setIsReady(true), 1500);
    return () => clearTimeout(timer);
  }, [setHasSeen]);

  return (
    <>
      {children}
      {tourActive && currentStep && isReady && <TourSpotlight />}
    </>
  );
}
