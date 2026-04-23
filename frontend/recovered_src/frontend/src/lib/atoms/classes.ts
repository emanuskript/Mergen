import { atom } from "jotai";
import { getClasses } from "../api/classes";
import { ManuscriptClass } from "../types/classes";

// ── Raw class list ──
export const classesAtom = atom<ManuscriptClass[]>([]);
export const classesLoadingAtom = atom(true);

// ── Selected class names ──
export const selectedClassNamesAtom = atom<Set<string>>(new Set<string>());

// ── Derived: color map ──
export const colorMapAtom = atom<Map<string, string>>((get) =>
  new Map(get(classesAtom).map((c) => [c.name, c.color])),
);

// ── Derived: selected names as array (for API calls) ──
export const selectedClassNamesArrayAtom = atom<string[]>((get) =>
  Array.from(get(selectedClassNamesAtom)),
);

// ── Write atom: fetch classes from API ──
export const fetchClassesAtom = atom(null, async (_get, set) => {
  set(classesLoadingAtom, true);
  try {
    const data = await getClasses();
    set(classesAtom, data);
    set(selectedClassNamesAtom, new Set(data.map((c) => c.name)));
  } finally {
    set(classesLoadingAtom, false);
  }
});

// ── Write atom: toggle a class ──
export const toggleClassAtom = atom(null, (get, set, name: string) => {
  const prev = get(selectedClassNamesAtom);
  const next = new Set(prev);
  if (next.has(name)) next.delete(name);
  else next.add(name);
  set(selectedClassNamesAtom, next);
});

// ── Write atom: select all ──
export const selectAllClassesAtom = atom(null, (get, set) => {
  set(selectedClassNamesAtom, new Set(get(classesAtom).map((c) => c.name)));
});

// ── Write atom: unselect all ──
export const unselectAllClassesAtom = atom(null, (_get, set) => {
  set(selectedClassNamesAtom, new Set<string>());
});
