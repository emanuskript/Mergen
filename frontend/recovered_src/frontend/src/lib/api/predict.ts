import { BatchInitResponse, BatchResults, PredictSingleResponse } from "../types/predict";
import { apiFetch } from "./client";

export async function predictSingle(
  image: File,
  confidence: number,
  iou: number,
  classes?: string[],
): Promise<PredictSingleResponse> {
  const form = new FormData();
  form.append("image", image);
  form.append("confidence", confidence.toString());
  form.append("iou", iou.toString());
  if (classes) {
    form.append("classes", JSON.stringify(classes));
  }
  return apiFetch<PredictSingleResponse>("/predict/single", {
    method: "POST",
    body: form,
  });
}

export async function predictBatch(
  zipFile: File,
  confidence: number,
  iou: number,
  classes?: string[],
): Promise<BatchInitResponse> {
  const form = new FormData();
  form.append("zip_file", zipFile);
  form.append("confidence", confidence.toString());
  form.append("iou", iou.toString());
  if (classes) {
    form.append("classes", JSON.stringify(classes));
  }
  return apiFetch<BatchInitResponse>("/predict/batch", {
    method: "POST",
    body: form,
  });
}

export async function getBatchResults(taskId: string): Promise<BatchResults> {
  return apiFetch<BatchResults>(`/predict/batch/${taskId}/results`);
}
