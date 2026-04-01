"use client";

import { ralewaySemibold } from "@/lib/fonts";
import { cn } from "@/lib/utils";

export type AppTopSection = "own" | "earn";

const OPTIONS: { id: AppTopSection; label: string }[] = [
  { id: "own", label: "Own" },
  { id: "earn", label: "Earn" },
];

type Props = {
  value: AppTopSection;
  onValueChange: (section: AppTopSection) => void;
};

export function AppTopMenu({ value, onValueChange }: Props) {
  return (
    <header className="sticky top-0 z-30 bg-transparent">
      <div className="mx-auto flex w-full max-w-lg justify-center px-4 py-3 sm:px-6">
        <nav
          className={cn(
            "inline-flex w-full max-w-xs flex-col gap-2 rounded-xl border border-white/25 px-2 pb-1.5 pt-3 shadow-md",
            "bg-background/82 backdrop-blur-xl backdrop-saturate-150",
            "ring-1 ring-black/6",
            "supports-backdrop-filter:bg-background/72",
          )}
          aria-label="App sections"
        >
          <p
            className={cn(
              ralewaySemibold.className,
              "px-1 text-center text-[1.5rem] font-semibold leading-none text-gray-900",
              "[font-variant-ligatures:common-ligatures]",
              "font-features-['liga'_1,'kern'_1,'ss01'_0,'cv01'_0]",
              "[text-rendering:optimizeLegibility]",
            )}
          >
            fluidstocks
          </p>
          <div className="flex gap-1 rounded-lg p-0.5" role="tablist">
            {OPTIONS.map((opt) => {
              const selected = value === opt.id;
              return (
                <button
                  key={opt.id}
                  type="button"
                  role="tab"
                  aria-selected={selected}
                  tabIndex={0}
                  className={cn(
                    "relative flex-1 rounded-lg px-4 py-2.5 text-sm font-semibold tracking-tight transition-[color,box-shadow,transform] duration-200",
                    selected
                      ? "bg-card text-foreground shadow-sm ring-1 ring-primary/10"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                  onClick={() => onValueChange(opt.id)}
                >
                  {selected ? (
                    <span
                      className="absolute inset-x-2 -bottom-px mx-auto h-0.5 max-w-10 rounded-full bg-primary"
                      aria-hidden
                    />
                  ) : null}
                  <span className="relative">{opt.label}</span>
                </button>
              );
            })}
          </div>
        </nav>
      </div>
    </header>
  );
}
