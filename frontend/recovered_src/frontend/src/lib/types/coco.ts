export interface COCOCategory {
  id: number;
  name: string;
  supercategory: string;
}

export interface COCOImage {
  id: number;
  width: number;
  height: number;
  file_name: string;
}

export interface COCOAnnotation {
  id: number;
  image_id: number;
  category_id: number;
  segmentation: number[][];
  bbox: [number, number, number, number];
  area: number;
  iscrowd: number;
}

export interface COCOJson {
  info: Record<string, string>;
  licenses: Record<string, string | number>[];
  images: COCOImage[];
  annotations: COCOAnnotation[];
  categories: COCOCategory[];
}
