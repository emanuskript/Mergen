"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTheme } from "next-themes";
import { Sun, Moon, Monitor, Contrast, Check } from "lucide-react";

const themes = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
  { value: "high-contrast", label: "High Contrast", icon: Contrast },
] as const;

export function ThemeToggle() {
  const { theme, setTheme, resolvedTheme } = useTheme();
  const mounted = useSyncExternalStore(
    () => () => undefined,
    () => true,
    () => false,
  );
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  // Close on outside click (matches Header dropdown pattern)
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  // Determine which icon to show on the button
  const activeTheme = theme === "system" ? resolvedTheme : theme;
  const ActiveIcon =
    themes.find((t) => t.value === activeTheme)?.icon ?? Sun;

  if (!mounted) {
    return <div className="h-8 w-8 rounded-md border" />;
  }

  return (
    <div ref={menuRef} className="relative">
      <button
        onClick={() => setOpen((o) => !o)}
        className="flex h-8 w-8 items-center justify-center rounded-md border text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
        title="Change theme"
        aria-label="Change theme"
      >
        <ActiveIcon className="h-4 w-4" />
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-1 w-44 rounded-md border bg-popover py-1 shadow-lg">
          {themes.map((t) => {
            const isActive = theme === t.value;
            return (
              <button
                key={t.value}
                onClick={() => {
                  setTheme(t.value);
                  setOpen(false);
                }}
                className={`flex w-full items-center gap-2 px-3 py-2 text-sm transition-colors ${
                  isActive
                    ? "bg-accent text-accent-foreground"
                    : "text-popover-foreground hover:bg-muted"
                }`}
              >
                <t.icon className="h-4 w-4" />
                {t.label}
                {isActive && <Check className="ml-auto h-3.5 w-3.5" />}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
