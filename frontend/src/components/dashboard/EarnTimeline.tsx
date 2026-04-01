"use client";

import { SquareArrowOutUpRight } from "lucide-react";
import { formatUnits } from "viem";
import {
  EARN_STEP2_TOKEN_DECIMALS,
  formatEarnYieldIndexerUsd,
} from "@/lib/api/xstocks";
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
import { RelayDepositFirstRow } from "./RelayDepositFirstRow";
import { TimelineMilestoneRow } from "./TimelineMilestoneRow";

const USDC_DECIMALS = 6;

export type EarnTimelineProps = {
  deposit: DepositFlowStatus;
  convert: TriStateFlowStatus;
  earn: TriStateFlowStatus;
  ausdBalanceWei: bigint;
  vaultUnderlyingWei: bigint;
  ausdDecimals: number | null;
  relayDepositAddress?: string | null;
  chainLabel?: string;
  usdcAmountRaw?: bigint | null;
  bankTxHash?: `0x${string}` | null;
  convertTxHash?: `0x${string}` | null;
  /** Indexer step-2 credited amount (6 decimals). */
  convertAmountRaw?: bigint | null;
  earnTxHash?: `0x${string}` | null;
  /** Indexer step-3 yield transfer `amount` (18 decimals); drives earn-row “$X”. */
  earnYieldAmountRaw?: bigint | null;
};

function formatUsdFromWei(wei: bigint, decimals: number | null): string {
  if (decimals == null) return "0";
  const n = Number(formatUnits(wei, decimals));
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

function formatUsdc(raw: bigint | null | undefined): string {
  if (raw == null || raw === 0n) return "—";
  const n = Number(formatUnits(raw, USDC_DECIMALS));
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

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

function TxLinkSlot({
  txHash,
  chainId,
  label,
}: {
  txHash?: `0x${string}` | null;
  chainId: number;
  label: string;
}) {
  if (!txHash) {
    return (
      <span
        className="size-9 shrink-0 opacity-0 pointer-events-none"
        aria-hidden
      />
    );
  }
  return <TimelineTxLink txHash={txHash} chainId={chainId} label={label} />;
}

export function EarnTimeline({
  deposit,
  convert,
  earn,
  ausdBalanceWei,
  vaultUnderlyingWei,
  ausdDecimals,
  relayDepositAddress,
  chainLabel = "Ethereum",
  usdcAmountRaw,
  bankTxHash,
  convertTxHash,
  convertAmountRaw,
  earnTxHash,
  earnYieldAmountRaw,
}: EarnTimelineProps) {
  const chainId = getEnv().chainId;

  const depositDone = deposit === "completed";
  const convertDone = convert === "completed";
  const earnDone = earn === "completed";

  const receivedWei =
    ausdBalanceWei > 0n ? ausdBalanceWei : vaultUnderlyingWei;
  const receivedUsd = formatUsdFromWei(receivedWei, ausdDecimals);
  const convertAusdDisplay =
    convertAmountRaw != null && convertAmountRaw > 0n
      ? Number(
          formatUnits(convertAmountRaw, EARN_STEP2_TOKEN_DECIMALS),
        ).toLocaleString(undefined, {
          minimumFractionDigits: 0,
          maximumFractionDigits: 2,
        })
      : null;
  /** After routing, on-chain AUSD is often 0; avoid showing "0" when we have no indexer amount yet. */
  const convertAmountLabel =
    convertAusdDisplay ??
    (receivedWei > 0n ? receivedUsd : null) ??
    "—";
  const earnVaultLabel =
    earnYieldAmountRaw != null && earnYieldAmountRaw > 0n
      ? formatEarnYieldIndexerUsd(earnYieldAmountRaw)
      : "—";
  const usdcDisplay = formatUsdc(usdcAmountRaw ?? null);
  const bankAmountLabel =
    usdcDisplay !== "—" ? usdcDisplay : receivedUsd;

  type RowKey = "funding" | "bank" | "convert" | "earn";
  const rows: RowKey[] = ["funding"];
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
      <div
        className="flex w-full min-w-0 flex-col gap-0"
        aria-label="Earn timeline"
      >
        {rows.map((key, i) => (
          <TimelineMilestoneRow key={key} isLast={i === rows.length - 1}>
            {key === "funding" ? (
              relayDepositAddress ? (
                <div className="flex w-full min-w-0 flex-col gap-0">
                  <SepaDepositFirstTimelineRow iban={SEPA_IBAN_EARN} />
                  <RelayDepositFirstRow
                    relayAddress={relayDepositAddress}
                    chainLabel={chainLabel}
                  />
                </div>
              ) : (
                <SepaDepositFirstTimelineRow iban={SEPA_IBAN_EARN} />
              )
            ) : null}
            {key === "bank" ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-base leading-snug text-foreground">
                  Received{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    ${bankAmountLabel}
                  </span>{" "}
                  {usdcDisplay !== "—" ? "USDC" : "from bank"}
                </p>
                <TxLinkSlot
                  txHash={normalizeTxHash(bankTxHash)}
                  chainId={chainId}
                  label="USDC deposit"
                />
              </div>
            ) : null}
            {key === "convert" ? (
              <div className="flex items-center justify-between gap-3">
                <p className="text-base leading-snug text-foreground">
                  Converted to{" "}
                  <span className="font-semibold tabular-nums text-primary">
                    {convertAmountLabel} AUSD
                  </span>
                </p>
                <TxLinkSlot
                  txHash={normalizeTxHash(convertTxHash)}
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
                    ${earnVaultLabel}
                  </span>
                </p>
                <TxLinkSlot
                  txHash={normalizeTxHash(earnTxHash)}
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

function normalizeTxHash(
  h: `0x${string}` | null | undefined,
): `0x${string}` | null {
  if (h && h.startsWith("0x") && h.length === 66) return h;
  return null;
}
