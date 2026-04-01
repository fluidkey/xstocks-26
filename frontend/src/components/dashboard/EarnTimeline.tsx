"use client";

import { SquareArrowOutUpRight } from "lucide-react";
import { formatUnits } from "viem";
import { blockExplorerTxUrl } from "@/lib/explorer";
import { getEnv } from "@/lib/env";
import { cn } from "@/lib/utils";
import type {
  DepositFlowStatus,
  TriStateFlowStatus,
} from "@/components/hero/HeroFlow";
import {
  SepaDepositFirstTimelineRow,
  SEPA_IBAN_EARN,
} from "./SepaDepositFirstTimelineRow";
import { TimelineMilestoneRow } from "./TimelineMilestoneRow";

export type EarnTimelineProps = {
  deposit: DepositFlowStatus;
  convert: TriStateFlowStatus;
  earn: TriStateFlowStatus;
  ausdBalanceWei: bigint;
  vaultUnderlyingWei: bigint;
  ausdDecimals: number | null;
  bankTxHash?: `0x${string}` | null;
  convertTxHash?: `0x${string}` | null;
  earnTxHash?: `0x${string}` | null;
};

function formatUsdFromWei(wei: bigint, decimals: number | null): string {
  if (decimals == null) return "0";
  const n = Number(formatUnits(wei, decimals));
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

const MOCK_BANK_TX_HASH =
  "0xa7f3c91e4b82d6058efa12c4b9d0e7536f18492caeb01d7f8e5a394bc206d817" as const;
const MOCK_CONVERT_TX_HASH =
  "0x4c1d8b9e2f70a56381edc9247fa03b6c59148ef2d3a7b09c45e118efad362904" as const;
const MOCK_EARN_TX_HASH =
  "0xb8e2a4f91c936d7398d5e9f0a6c7b3d1e4f8a2c5061728394a5b6c7d8e9f0a1b2" as const;

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

export function EarnTimeline({
  deposit,
  convert,
  earn,
  ausdBalanceWei,
  vaultUnderlyingWei,
  ausdDecimals,
  bankTxHash,
  convertTxHash,
  earnTxHash,
}: EarnTimelineProps) {
  const chainId = getEnv().chainId;

  const depositDone = deposit === "completed";
  const convertDone = convert === "completed";
  const earnDone = earn === "completed";

  const receivedWei =
    ausdBalanceWei > 0n ? ausdBalanceWei : vaultUnderlyingWei;
  const receivedUsd = formatUsdFromWei(receivedWei, ausdDecimals);
  const vaultUsd = formatUsdFromWei(vaultUnderlyingWei, ausdDecimals);

  const effectiveBankTx = (bankTxHash ?? MOCK_BANK_TX_HASH) as `0x${string}`;
  const effectiveConvertTx = (convertTxHash ??
    MOCK_CONVERT_TX_HASH) as `0x${string}`;
  const effectiveEarnTx = (earnTxHash ?? MOCK_EARN_TX_HASH) as `0x${string}`;

  type RowKey = "sepa" | "bank" | "convert" | "earn";
  const rows: RowKey[] = ["sepa"];
  if (depositDone) rows.push("bank");
  if (convertDone) rows.push("convert");
  if (earnDone) rows.push("earn");

  return (
    <div
      className={cn(
        "w-full rounded-2xl border border-border/90 bg-card/55 px-4 py-5 shadow-sm",
        "ring-1 ring-black/3 sm:px-6 sm:py-6",
      )}
    >
      <div className="flex w-full min-w-0 flex-col gap-0" aria-label="Earn timeline">
        {rows.map((key, i) => (
          <TimelineMilestoneRow key={key} isLast={i === rows.length - 1}>
            {key === "sepa" ? (
              <SepaDepositFirstTimelineRow iban={SEPA_IBAN_EARN} />
            ) : null}
            {key === "bank" ? (
              <div className="flex items-center justify-between gap-3">
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
            {key === "convert" ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-base leading-snug text-foreground">
                  Converted to{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    {receivedUsd} AUSD
                  </span>
                </p>
                <TimelineTxLink
                  txHash={effectiveConvertTx}
                  chainId={chainId}
                  label="AUSD conversion"
                />
              </div>
            ) : null}
            {key === "earn" ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-base leading-snug text-foreground">
                  Earning yield on{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    ${vaultUsd}
                  </span>
                </p>
                <TimelineTxLink
                  txHash={effectiveEarnTx}
                  chainId={chainId}
                  label="vault position"
                />
              </div>
            ) : null}
          </TimelineMilestoneRow>
        ))}
      </div>
    </div>
  );
}
