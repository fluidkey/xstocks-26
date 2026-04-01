"use client";

import { formatUnits } from "viem";
import { OwnFlow } from "@/components/own/OwnFlow";
import type { OwnFlowProps } from "@/components/own/OwnFlow";

export type { BankStepStatus, TslaxStepStatus } from "@/components/own/OwnFlow";

type Props = {
  /** Hero line: quantity wei + decimals (Morpho assets or indexer TSLAx). */
  headerTslaxQtyWei: bigint;
  headerTslaxQtyDecimals: number | null;
  /** Vault underlying for timeline (“purchased” step imagery). */
  vaultUnderlyingWei: bigint;
  /** AUSD on the Own Safe (timeline “received from bank”). */
  ausdBalanceWei: bigint;
  ausdDecimals: number | null;
  /** Tesla xStock USD price from prices feed; second line = qty × this. */
  tslaxPriceUsd: number | null;
  /** Prices feed still loading (show placeholder for USD line when qty > 0). */
  tslaxPriceLoading: boolean;
  sendFromBank: OwnFlowProps["sendFromBank"];
  buyTslax: OwnFlowProps["buyTslax"];
  teslaDecimals: number | null;
  bankAmountRaw: bigint | null;
  tslaxAmountRaw: bigint | null;
  bankTxHash: `0x${string}` | null;
  tslaxTxHash: `0x${string}` | null;
  relayDepositAddress: `0x${string}` | null;
  chainLabel: string;
};

function OwnBalanceHeader({
  headerTslaxQtyWei,
  headerTslaxQtyDecimals,
  tslaxPriceUsd,
  tslaxPriceLoading,
}: {
  headerTslaxQtyWei: bigint;
  headerTslaxQtyDecimals: number | null;
  tslaxPriceUsd: number | null;
  tslaxPriceLoading: boolean;
}) {
  const parsed =
    headerTslaxQtyDecimals == null
      ? null
      : Number(formatUnits(headerTslaxQtyWei, headerTslaxQtyDecimals));

  const qty =
    parsed == null || parsed === 0
      ? "0"
      : parsed.toLocaleString(undefined, { maximumFractionDigits: 6 });

  const usdLine =
    parsed == null || parsed === 0
      ? "0"
      : tslaxPriceLoading
        ? "…"
        : tslaxPriceUsd != null && Number.isFinite(tslaxPriceUsd)
          ? (parsed * tslaxPriceUsd).toLocaleString(undefined, {
              minimumFractionDigits: 0,
              maximumFractionDigits: 2,
            })
          : "—";

  return (
    <header className="flex w-full flex-col items-center text-center">
      <p className="text-balance text-4xl font-semibold tabular-nums tracking-tight text-primary/85 sm:text-5xl">
        {qty}{" "}
        <span className="text-3xl font-semibold sm:text-4xl">TSLAx</span>
      </p>
      <p className="mt-2 text-xl font-medium tabular-nums tracking-tight text-muted-foreground sm:text-2xl">
        <span>$</span>
        {usdLine}
      </p>
    </header>
  );
}

export function OwnPanel({
  headerTslaxQtyWei,
  headerTslaxQtyDecimals,
  vaultUnderlyingWei,
  ausdBalanceWei,
  ausdDecimals,
  tslaxPriceUsd,
  tslaxPriceLoading,
  sendFromBank,
  buyTslax,
  teslaDecimals,
  bankAmountRaw,
  tslaxAmountRaw,
  bankTxHash,
  tslaxTxHash,
  relayDepositAddress,
  chainLabel,
}: Props) {
  return (
    <div className="flex w-full flex-col gap-10">
      <OwnBalanceHeader
        headerTslaxQtyWei={headerTslaxQtyWei}
        headerTslaxQtyDecimals={headerTslaxQtyDecimals}
        tslaxPriceUsd={tslaxPriceUsd}
        tslaxPriceLoading={tslaxPriceLoading}
      />
      <OwnFlow
        sendFromBank={sendFromBank}
        buyTslax={buyTslax}
        ausdBalanceWei={ausdBalanceWei}
        vaultUnderlyingWei={vaultUnderlyingWei}
        ausdDecimals={ausdDecimals}
        teslaDecimals={teslaDecimals}
        bankAmountRaw={bankAmountRaw}
        tslaxAmountRaw={tslaxAmountRaw}
        bankTxHash={bankTxHash}
        tslaxTxHash={tslaxTxHash}
        relayDepositAddress={relayDepositAddress}
        chainLabel={chainLabel}
      />
    </div>
  );
}
