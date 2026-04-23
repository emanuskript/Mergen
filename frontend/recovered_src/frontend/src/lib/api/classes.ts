import { ManuscriptClass } from "../types/classes";
import { apiFetch } from "./client";

export async function getClasses(): Promise<ManuscriptClass[]> {
  const data = await apiFetch<{ classes: ManuscriptClass[] }>("/classes");
  return data.classes;
}
