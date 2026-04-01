"use client";

import type { ReactNode } from "react";
import { ArrowRight, SquareArrowOutUpRight } from "lucide-react";
import Image from "next/image";
import { formatUnits } from "viem";
import { blockExplorerTxUrl } from "@/lib/explorer";
import { getEnv } from "@/lib/env";
import { cn } from "@/lib/utils";
import {
  SepaDepositFirstTimelineRow,
  SEPA_IBAN_OWN,
} from "@/components/dashboard/SepaDepositFirstTimelineRow";
import { TimelineMilestoneRow } from "@/components/dashboard/TimelineMilestoneRow";

export type BankStepStatus = "pending" | "completed";
export type TslaxStepStatus = "pending" | "processing" | "completed";

export type OwnFlowProps = {
  sendFromBank: BankStepStatus;
  buyTslax: TslaxStepStatus;
  /** AUSD on the stealth Safe (for “received from bank”). */
  ausdBalanceWei: bigint;
  /** Vault underlying / TSLAx position (for “purchased”). */
  vaultUnderlyingWei: bigint;
  ausdDecimals: number | null;
  /** Set when the bank / AUSD transfer tx is known (Etherscan link on timeline). */
  bankTxHash?: `0x${string}` | null;
  /** Set when the vault / TSLAx purchase tx is known. */
  tslaxTxHash?: `0x${string}` | null;
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

function tslaxImageSrc(status: TslaxStepStatus): string {
  if (status === "completed") return "/own/tesla_done.png";
  return "/own/tesla_pending.png";
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

function BankStepImage({
  sendFromBank,
  bankVisualActive,
  bankDone,
  imageMb,
}: {
  sendFromBank: BankStepStatus;
  bankVisualActive: boolean;
  bankDone: boolean;
  imageMb: string;
}) {
  return (
    <div
      className={cn(
        "relative w-full overflow-hidden rounded-3xl border bg-card/60 shadow-sm ring-1 ring-black/3 transition-[box-shadow,border-color] duration-500",
        imageMb,
        bankVisualActive
          ? "hero-flow-step-glow border-primary/30 ring-primary/10"
          : "border-border/90",
        bankDone && "border-primary/20",
      )}
    >
      <div className="relative aspect-square w-full">
        <Image
          src={
            sendFromBank === "pending"
              ? "/own/bank_full.png"
              : "/own/bank_empty.png"
          }
          alt=""
          fill
          className="object-cover object-center"
          sizes="(max-width: 640px) 100vw, (max-width: 1024px) 46vw, 560px"
          priority={false}
        />
      </div>
      {bankVisualActive ? (
        <span
          className="hero-flow-ping pointer-events-none absolute inset-0 rounded-2xl ring-2 ring-primary/15"
          aria-hidden
        />
      ) : null}
    </div>
  );
}

function TslaxStepImage({
  buyTslax,
  tslaxActive,
  tslaxDone,
  bankDone,
  imageMb,
}: {
  buyTslax: TslaxStepStatus;
  tslaxActive: boolean;
  tslaxDone: boolean;
  bankDone: boolean;
  imageMb: string;
}) {
  return (
    <div
      className={cn(
        "relative w-full overflow-hidden rounded-3xl border bg-card/60 shadow-sm ring-1 ring-black/3 transition-[box-shadow,border-color] duration-500",
        imageMb,
        "border-border/90",
        tslaxActive && "hero-flow-step-glow border-primary/30 ring-primary/10",
        tslaxDone && "border-primary/20",
        !bankDone && "opacity-90",
      )}
    >
      <div className="relative aspect-square w-full">
        <Image
          src={tslaxImageSrc(buyTslax)}
          alt=""
          fill
          className="object-cover object-center"
          sizes="(max-width: 640px) 100vw, (max-width: 1024px) 46vw, 560px"
          priority={false}
        />
      </div>
      {tslaxActive && !tslaxDone ? (
        <span
          className={cn(
            "hero-flow-ping pointer-events-none absolute inset-0 rounded-2xl ring-2 ring-primary/15",
            buyTslax === "pending" && "opacity-70 ring-primary/10",
          )}
          aria-hidden
        />
      ) : null}
    </div>
  );
}

function BankStepCopy({ badge }: { badge: ReactNode }) {
  return (
    <>
      <p className="text-sm font-semibold uppercase tracking-[0.18em] text-primary/85 sm:text-base">
        <span className="tabular-nums">1.</span> Send from bank
      </p>
      {badge}
    </>
  );
}

function TslaxStepCopy({ badge }: { badge: ReactNode }) {
  return (
    <>
      <p className="text-sm font-semibold uppercase tracking-[0.18em] text-primary/85 sm:text-base">
        <span className="tabular-nums">2.</span> Own TSLAx
      </p>
      {badge}
    </>
  );
}

function formatUsdFromWei(wei: bigint, decimals: number | null): string {
  if (decimals == null) return "0";
  const n = Number(formatUnits(wei, decimals));
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

function formatTslaxQty(wei: bigint, decimals: number | null): string {
  if (decimals == null) return "0";
  const n = Number(formatUnits(wei, decimals));
  return n === 0
    ? "0"
    : n.toLocaleString(undefined, { maximumFractionDigits: 6 });
}

/** Plausible mock tx hashes for timeline explorer links until real txs are wired. */
const MOCK_BANK_TX_HASH =
  "0xa7f3c91e4b82d6058efa12c4b9d0e7536f18492caeb01d7f8e5a394bc206d817" as const;
const MOCK_TSLAX_TX_HASH =
  "0x4c1d8b9e2f70a56381edc9247fa03b6c59148ef2d3a7b09c45e118efad362904" as const;

function TimelineTxLink({
  txHash,
  chainId,
  label,
}: {
  txHash: `0x${string}`;
  chainId: number;
  label: string;
}) {
  const href = blockExplorerTxUrl(chainId, txHash);
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(
        "flex size-9 shrink-0 items-center justify-center rounded-lg border border-transparent",
        "text-muted-foreground transition-colors",
        "hover:border-border hover:bg-muted/60 hover:text-primary",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
      )}
      aria-label={`View ${label} on block explorer`}
    >
      <SquareArrowOutUpRight className="size-5" strokeWidth={2} aria-hidden />
    </a>
  );
}

function OwnTimeline({
  sendFromBank,
  buyTslax,
  ausdBalanceWei,
  vaultUnderlyingWei,
  ausdDecimals,
  bankTxHash,
  tslaxTxHash,
}: OwnFlowProps) {
  const chainId = getEnv().chainId;

  const bankDone = sendFromBank === "completed";
  const tslaxDone = buyTslax === "completed";

  const receivedWei =
    ausdBalanceWei > 0n ? ausdBalanceWei : vaultUnderlyingWei;
  const receivedUsd = formatUsdFromWei(receivedWei, ausdDecimals);
  const tslaxQty = formatTslaxQty(vaultUnderlyingWei, ausdDecimals);

  const effectiveBankTx = (bankTxHash ?? MOCK_BANK_TX_HASH) as `0x${string}`;
  const effectiveTslaxTx = (tslaxTxHash ?? MOCK_TSLAX_TX_HASH) as `0x${string}`;

  const ROW_H = "h-7";

  type RowKey = "sepa" | "bank" | "tslax";
  const rows: RowKey[] = ["sepa"];
  if (bankDone) rows.push("bank");
  if (tslaxDone) rows.push("tslax");

  return (
    <div
      className={cn(
        "mt-12 w-full rounded-2xl border border-border/90 bg-card/55 px-4 py-5 shadow-sm",
        "ring-1 ring-black/3 sm:mt-14 sm:px-6 sm:py-6",
      )}
    >
      <div
        className="flex w-full min-w-0 flex-col gap-0"
        aria-label="Funding timeline"
      >
        {rows.map((key, i) => (
          <TimelineMilestoneRow key={key} isLast={i === rows.length - 1}>
            {key === "sepa" ? (
              <SepaDepositFirstTimelineRow iban={SEPA_IBAN_OWN} />
            ) : null}
            {key === "bank" ? (
              <div className={cn("flex items-center justify-between gap-3", ROW_H)}>
                <p className="text-base leading-snug text-foreground">
                  Received{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    ${receivedUsd}
                  </span>{" "}
                  from bank
                </p>
                <TimelineTxLink
                  txHash={effectiveBankTx}
                  chainId={chainId}
                  label="bank transfer"
                />
              </div>
            ) : null}
            {key === "tslax" ? (
              <div className={cn("flex items-center justify-between gap-3", ROW_H)}>
                <p className="text-base leading-snug text-foreground">
                  Purchased{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    {tslaxQty} TSLAx
                  </span>
                </p>
                <TimelineTxLink
                  txHash={effectiveTslaxTx}
                  chainId={chainId}
                  label="TSLAx purchase"
                />
              </div>
            ) : null}
          </TimelineMilestoneRow>
        ))}
      </div>
    </div>
  );
}

export function OwnFlow(props: OwnFlowProps) {
  const { sendFromBank, buyTslax } = props;
  const bankDone = sendFromBank === "completed";
  const bankVisualActive = sendFromBank === "pending";

  const tslaxDone = buyTslax === "completed";
  const tslaxActive =
    buyTslax === "processing" ||
    (buyTslax === "pending" && bankDone);

  const badgeBank =
    sendFromBank === "completed"
      ? stepBadge("Completed", "completed")
      : stepBadge("Pending", "pending");

  const badgeTslax =
    buyTslax === "completed"
      ? stepBadge("Completed", "completed")
      : buyTslax === "processing"
        ? stepBadge("Processing", "processing")
        : stepBadge("Pending", "pending");

  return (
    <section
      className="w-full"
      aria-label="Own: bank funding and TSLAx"
    >
      <div className="mx-auto w-[80%] max-w-full">
        {/* Mobile: stacked steps; connector omitted */}
        <div className="flex flex-col gap-12 sm:hidden">
          <div className="flex min-w-0 w-full flex-col items-center">
            <BankStepImage
              sendFromBank={sendFromBank}
              bankVisualActive={bankVisualActive}
              bankDone={bankDone}
              imageMb="mb-4"
            />
            <div className="flex flex-col items-center">
              <BankStepCopy badge={badgeBank} />
            </div>
          </div>
          <div className="flex min-w-0 w-full flex-col items-center">
            <TslaxStepImage
              buyTslax={buyTslax}
              tslaxActive={tslaxActive}
              tslaxDone={tslaxDone}
              bankDone={bankDone}
              imageMb="mb-4"
            />
            <div className="flex flex-col items-center">
              <TslaxStepCopy badge={badgeTslax} />
            </div>
          </div>
        </div>

        {/* Desktop: image row + connector aligned to image vertical center */}
        <div className="hidden flex-col gap-8 sm:flex">
          <div className="grid w-full grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-x-5">
            <BankStepImage
              sendFromBank={sendFromBank}
              bankVisualActive={bankVisualActive}
              bankDone={bankDone}
              imageMb=""
            />
            <FlowConnector active={bankDone} />
            <TslaxStepImage
              buyTslax={buyTslax}
              tslaxActive={tslaxActive}
              tslaxDone={tslaxDone}
              bankDone={bankDone}
              imageMb=""
            />
          </div>
          <div className="grid w-full grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] gap-x-5">
            <div className="flex min-w-0 flex-col items-center">
              <BankStepCopy badge={badgeBank} />
            </div>
            <div className="invisible pointer-events-none" aria-hidden>
              <FlowConnector active={bankDone} />
            </div>
            <div className="flex min-w-0 flex-col items-center">
              <TslaxStepCopy badge={badgeTslax} />
            </div>
          </div>
        </div>
      </div>

      <OwnTimeline {...props} />
    </section>
  );
}
