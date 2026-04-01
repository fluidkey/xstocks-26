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

/**
 * One timeline step: dot + stem beside body.
 * Dot is centered on the first line using the same `text-base` + `leading-snug` as body text:
 * - Rail uses `h-[1lh]` so its height equals the first line box of the copy.
 * - Dot is absolutely positioned at `50% + 0.48ex` then `translate(-50%,-50%)`, so the
 *   vertical nudge scales with the font’s x-height (matches Work Sans metrics at any zoom).
 */
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
        className="flex h-full min-h-0 w-6 shrink-0 flex-col items-center text-base leading-snug"
        aria-hidden
      >
        <div className="relative isolate h-lh w-full shrink-0">
          <span
            className="absolute left-1/2 top-[calc(50%+0.48ex)] -translate-x-1/2 -translate-y-1/2"
            aria-hidden
          >
            <TimelineDot />
          </span>
        </div>
        {!isLast ? (
          <div className="min-h-12 w-px flex-1 bg-primary/25" />
        ) : null}
      </div>
      <div className="min-w-0 flex-1 text-base leading-snug [&_p]:leading-snug">
        {children}
      </div>
    </div>
  );
}
