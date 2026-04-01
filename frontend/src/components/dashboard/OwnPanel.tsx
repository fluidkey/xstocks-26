"use client";

import { useMemo, useState } from "react";
import { formatUnits } from "viem";
import { OwnFlow } from "@/components/own/OwnFlow";
import type { OwnFlowProps } from "@/components/own/OwnFlow";
import { Button } from "@/components/ui/button";

export type { BankStepStatus, TslaxStepStatus } from "@/components/own/OwnFlow";

const DEMO_STEPS: Pick<OwnFlowProps, "sendFromBank" | "buyTslax">[] = [
  { sendFromBank: "pending", buyTslax: "pending" },
  { sendFromBank: "completed", buyTslax: "pending" },
  { sendFromBank: "completed", buyTslax: "processing" },
  { sendFromBank: "completed", buyTslax: "completed" },
];

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
  sendFromBank: liveSendFromBank,
  buyTslax: liveBuyTslax,
  teslaDecimals: liveTeslaDecimals,
  bankAmountRaw: liveBankAmountRaw,
  tslaxAmountRaw: liveTslaxAmountRaw,
  bankTxHash: liveBankTxHash,
  tslaxTxHash: liveTslaxTxHash,
  relayDepositAddress: liveRelayDepositAddress,
  chainLabel: liveChainLabel,
}: Props) {
  const [demoIndex, setDemoIndex] = useState<number | null>(null);

  const ownFlowProps: OwnFlowProps = useMemo(() => {
    const step = demoIndex !== null ? DEMO_STEPS[demoIndex] : null;
    const liveTimeline = demoIndex === null;
    return {
      sendFromBank: step?.sendFromBank ?? liveSendFromBank,
      buyTslax: step?.buyTslax ?? liveBuyTslax,
      ausdBalanceWei,
      vaultUnderlyingWei,
      ausdDecimals,
      teslaDecimals: liveTeslaDecimals,
      bankAmountRaw: liveTimeline ? liveBankAmountRaw : null,
      tslaxAmountRaw: liveTimeline ? liveTslaxAmountRaw : null,
      bankTxHash: liveTimeline ? liveBankTxHash : null,
      tslaxTxHash: liveTimeline ? liveTslaxTxHash : null,
      relayDepositAddress: liveRelayDepositAddress,
      chainLabel: liveChainLabel,
    };
  }, [
    demoIndex,
    liveSendFromBank,
    liveBuyTslax,
    ausdBalanceWei,
    vaultUnderlyingWei,
    ausdDecimals,
    liveTeslaDecimals,
    liveBankAmountRaw,
    liveTslaxAmountRaw,
    liveBankTxHash,
    liveTslaxTxHash,
    liveRelayDepositAddress,
    liveChainLabel,
  ]);

  function advanceDemo() {
    setDemoIndex((i) => {
      if (i === null) return 0;
      if (i < DEMO_STEPS.length - 1) return i + 1;
      return null;
    });
  }

  return (
    <div className="flex w-full flex-col gap-10">
      <OwnBalanceHeader
        headerTslaxQtyWei={headerTslaxQtyWei}
        headerTslaxQtyDecimals={headerTslaxQtyDecimals}
        tslaxPriceUsd={tslaxPriceUsd}
        tslaxPriceLoading={tslaxPriceLoading}
      />
      <OwnFlow {...ownFlowProps} />
      <div className="flex flex-col items-center gap-3 border-t border-border/60 pt-8">
        {demoIndex !== null ? (
          <p className="text-center text-xs text-muted-foreground">
            Demo preview — not your live on-chain status.
          </p>
        ) : null}
        <div className="flex flex-wrap items-center justify-center gap-3">
          <Button
            type="button"
            variant="outline"
            size="default"
            className="min-w-[10rem]"
            onClick={advanceDemo}
          >
            {demoIndex === null
              ? "Preview steps"
              : demoIndex < DEMO_STEPS.length - 1
                ? `Next step (${demoIndex + 1}/${DEMO_STEPS.length})`
                : "Finish preview"}
          </Button>
          {demoIndex !== null ? (
            <Button
              type="button"
              variant="ghost"
              size="default"
              onClick={() => setDemoIndex(null)}
            >
              Use live status
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
