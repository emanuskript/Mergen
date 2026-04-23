import { COCOJson } from "./coco";

export interface PredictSingleResponse {
  task_id: string;
  coco_json: COCOJson;
  stats: Record<string, number>;
  annotated_image_url: string;
}

export interface BatchInitResponse {
  task_id: string;
  sse_url: string;
}

export interface BatchProgress {
  status: "pending" | "processing" | "completed" | "error";
  progress: number;
  total: number;
  current_image: string;
  message: string;
}

export interface GalleryItem {
  filename: string;
  annotated_url: string;
}

export interface BatchResults {
  status: string;
  total_processed: number;
  errors: string[];
  coco_json: COCOJson;
  stats_per_image: { image: string; stats: Record<string, number> }[];
  stats_summary: Record<string, number>;
  gallery: GalleryItem[];
}
