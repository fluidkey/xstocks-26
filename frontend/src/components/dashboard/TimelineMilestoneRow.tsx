"use client";

import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

export function TimelineDot() {
  return (
    <span
      className={cn(
        "z-10 size-3 shrink-0 rounded-full border-2 border-primary/70 bg-background shadow-sm",
        "ring-2 ring-background",
      )}
      aria-hidden
    />
  );
}

/** One timeline step: dot + stem (to next step) beside body. Stem grows with body height. */
export function TimelineMilestoneRow({
  isLast,
  children,
}: {
  isLast: boolean;
  children: ReactNode;
}) {
  return (
    <div className="flex min-w-0 items-stretch gap-4">
      <div
        className="flex w-6 shrink-0 flex-col items-center pt-1.5"
        aria-hidden
      >
        <TimelineDot />
        {!isLast ? (
          <div className="mt-0 min-h-12 w-px flex-1 bg-primary/25" />
        ) : null}
      </div>
      <div className="min-w-0 flex-1">{children}</div>
    </div>
  );
}
