import { BatchProgress } from "../types/predict";
import { apiUrl } from "./client";

export function subscribeBatchProgress(
  taskId: string,
  onProgress: (data: BatchProgress) => void,
  onError?: (error: Event) => void,
): () => void {
  const url = apiUrl(`/predict/batch/${taskId}/progress`);
  const source = new EventSource(url);

  source.onmessage = (event) => {
    const data: BatchProgress = JSON.parse(event.data);
    onProgress(data);
    if (data.status === "completed" || data.status === "error") {
      source.close();
    }
  };

  source.onerror = (event) => {
    onError?.(event);
    source.close();
  };

  return () => source.close();
}
