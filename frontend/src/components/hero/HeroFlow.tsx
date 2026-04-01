"use client";

import type { ReactNode } from "react";
import { ArrowRight } from "lucide-react";
import Image from "next/image";
import { cn } from "@/lib/utils";

export type DepositFlowStatus = "not_started" | "completed";
export type TriStateFlowStatus = "not_started" | "processing" | "completed";

export type HeroFlowStatuses = {
  deposit: DepositFlowStatus;
  convert: TriStateFlowStatus;
  earn: TriStateFlowStatus;
};

function FlowConnector({ active }: { active: boolean }) {
  return (
    <div className="flex shrink-0 items-center justify-center" aria-hidden>
      <ArrowRight
        className={cn(
          "size-8 transition-colors duration-300 sm:size-10",
          active ? "text-primary" : "text-muted-foreground",
        )}
        strokeWidth={2}
      />
    </div>
  );
}

function stepBadge(
  label: string,
  variant: "pending" | "processing" | "completed",
) {
  return (
    <span
      className={cn(
        "mt-3 inline-flex rounded-full px-3.5 py-1.5 text-xs font-semibold uppercase tracking-wide sm:mt-4 sm:px-4 sm:py-2 sm:text-sm",
        variant === "pending" &&
          "border border-neutral-300/80 bg-neutral-200/80 text-neutral-700",
        variant === "processing" &&
          "border border-orange-300/70 bg-orange-100/90 text-orange-900",
        variant === "completed" &&
          "border border-emerald-300/70 bg-emerald-100/90 text-emerald-900",
      )}
    >
      {label}
    </span>
  );
}

function depositImageSrc(s: DepositFlowStatus): string {
  return s === "completed" ? "/own/bank_empty.png" : "/own/bank_full.png";
}

function convertImageSrc(s: TriStateFlowStatus): string {
  if (s === "completed") return "/own/ausd_done.png";
  return "/own/ausd_pending.png";
}

function earnImageSrc(s: TriStateFlowStatus): string {
  if (s === "completed") return "/own/morpho_done.png";
  return "/own/morpho_pending.png";
}

function StepImage({
  src,
  showPing,
  highlight,
  done,
  dimmed,
  imageMb,
}: {
  src: string;
  showPing: boolean;
  highlight: boolean;
  done: boolean;
  dimmed?: boolean;
  imageMb: string;
}) {
  return (
    <div
      className={cn(
        "relative w-full overflow-hidden rounded-3xl border bg-card/60 shadow-sm ring-1 ring-black/3 transition-[box-shadow,border-color] duration-500",
        imageMb,
        highlight && "hero-flow-step-glow border-primary/30 ring-primary/10",
        done && "border-primary/20",
        !highlight && !done && "border-border/90",
        dimmed && "opacity-90",
      )}
    >
      <div className="relative aspect-square w-full">
        <Image
          src={src}
          alt=""
          fill
          className="object-cover object-center"
          sizes="(max-width: 640px) 100vw, (max-width: 1024px) 30vw, 360px"
          priority={false}
        />
      </div>
      {showPing ? (
        <span
          className="hero-flow-ping pointer-events-none absolute inset-0 rounded-2xl ring-2 ring-primary/15"
          aria-hidden
        />
      ) : null}
    </div>
  );
}

function StepTitle({
  step,
  children,
}: {
  step: number;
  children: ReactNode;
}) {
  return (
    <p className="text-sm font-semibold uppercase tracking-[0.18em] text-primary/85 sm:text-base">
      <span className="tabular-nums">{step}.</span> {children}
    </p>
  );
}

function depositBadge(s: DepositFlowStatus) {
  return s === "completed"
    ? stepBadge("Completed", "completed")
    : stepBadge("Pending", "pending");
}

function triBadge(s: TriStateFlowStatus) {
  if (s === "completed") return stepBadge("Completed", "completed");
  if (s === "processing") return stepBadge("Processing", "processing");
  return stepBadge("Pending", "pending");
}

export function HeroFlow({ deposit, convert, earn }: HeroFlowStatuses) {
  const depositDone = deposit === "completed";
  const convertDone = convert === "completed";
  const earnDone = earn === "completed";

  const depositPing = deposit === "not_started";
  const convertActive =
    convert === "processing" ||
    (convert === "not_started" && depositDone);
  const convertPing = convertActive && !convertDone;
  const earnActive =
    earn === "processing" || (earn === "not_started" && convertDone);
  const earnPing = earnActive && !earnDone;

  return (
    <section className="w-full" aria-label="Earn: send from bank, convert to AUSD, earn yield">
      {/* Mobile */}
      <div className="flex flex-col gap-12 sm:hidden">
        <div className="flex min-w-0 w-full flex-col items-center">
          <StepImage
            src={depositImageSrc(deposit)}
            showPing={depositPing}
            highlight={depositPing}
            done={depositDone}
            imageMb="mb-4"
          />
          <div className="flex flex-col items-center">
            <StepTitle step={1}>Send from bank</StepTitle>
            {depositBadge(deposit)}
          </div>
        </div>
        <div className="flex min-w-0 w-full flex-col items-center">
          <StepImage
            src={convertImageSrc(convert)}
            showPing={convertPing}
            highlight={convertActive}
            done={convertDone}
            dimmed={!depositDone}
            imageMb="mb-4"
          />
          <div className="flex flex-col items-center">
            <StepTitle step={2}>Convert to AUSD</StepTitle>
            {triBadge(convert)}
          </div>
        </div>
        <div className="flex min-w-0 w-full flex-col items-center">
          <StepImage
            src={earnImageSrc(earn)}
            showPing={earnPing}
            highlight={earnActive}
            done={earnDone}
            dimmed={!convertDone}
            imageMb="mb-4"
          />
          <div className="flex flex-col items-center">
            <StepTitle step={3}>Earn yield</StepTitle>
            {triBadge(earn)}
          </div>
        </div>
      </div>

      {/* Desktop */}
      <div className="hidden flex-col gap-8 sm:flex">
        <div className="grid w-full grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-x-5">
          <StepImage
            src={depositImageSrc(deposit)}
            showPing={depositPing}
            highlight={depositPing}
            done={depositDone}
            imageMb=""
          />
          <FlowConnector active={depositDone} />
          <StepImage
            src={convertImageSrc(convert)}
            showPing={convertPing}
            highlight={convertActive}
            done={convertDone}
            dimmed={!depositDone}
            imageMb=""
          />
          <FlowConnector active={convertDone} />
          <StepImage
            src={earnImageSrc(earn)}
            showPing={earnPing}
            highlight={earnActive}
            done={earnDone}
            dimmed={!convertDone}
            imageMb=""
          />
        </div>
        <div className="grid w-full grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)] gap-x-5">
          <div className="flex min-w-0 flex-col items-center">
            <StepTitle step={1}>Send from bank</StepTitle>
            {depositBadge(deposit)}
          </div>
          <div className="invisible pointer-events-none" aria-hidden>
            <FlowConnector active={depositDone} />
          </div>
          <div className="flex min-w-0 flex-col items-center">
            <StepTitle step={2}>Convert to AUSD</StepTitle>
            {triBadge(convert)}
          </div>
          <div className="invisible pointer-events-none" aria-hidden>
            <FlowConnector active={convertDone} />
          </div>
          <div className="flex min-w-0 flex-col items-center">
            <StepTitle step={3}>Earn yield</StepTitle>
            {triBadge(earn)}
          </div>
        </div>
      </div>
    </section>
  );
}
