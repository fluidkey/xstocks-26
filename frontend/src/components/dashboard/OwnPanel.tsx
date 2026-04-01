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
  /** Vault underlying for header + timeline (“TSLAx” / purchased). */
  tslaxBalanceWei: bigint;
  /** AUSD on the active stealth Safe (timeline “received from bank”). */
  ausdBalanceWei: bigint;
  ausdDecimals: number | null;
  /** Tesla xStock USD price from prices feed; second line = qty × this. */
  tslaxPriceUsd: number | null;
  /** Prices feed still loading (show placeholder for USD line when qty > 0). */
  tslaxPriceLoading: boolean;
  sendFromBank: OwnFlowProps["sendFromBank"];
  buyTslax: OwnFlowProps["buyTslax"];
};

function OwnBalanceHeader({
  tslaxBalanceWei,
  ausdDecimals,
  tslaxPriceUsd,
  tslaxPriceLoading,
}: {
  tslaxBalanceWei: bigint;
  ausdDecimals: number | null;
  tslaxPriceUsd: number | null;
  tslaxPriceLoading: boolean;
}) {
  const parsed =
    ausdDecimals == null
      ? null
      : Number(formatUnits(tslaxBalanceWei, ausdDecimals));

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
  tslaxBalanceWei,
  ausdBalanceWei,
  ausdDecimals,
  tslaxPriceUsd,
  tslaxPriceLoading,
  sendFromBank: liveSendFromBank,
  buyTslax: liveBuyTslax,
}: Props) {
  const [demoIndex, setDemoIndex] = useState<number | null>(null);

  const ownFlowProps: OwnFlowProps = useMemo(() => {
    const step = demoIndex !== null ? DEMO_STEPS[demoIndex] : null;
    return {
      sendFromBank: step?.sendFromBank ?? liveSendFromBank,
      buyTslax: step?.buyTslax ?? liveBuyTslax,
      ausdBalanceWei,
      vaultUnderlyingWei: tslaxBalanceWei,
      ausdDecimals,
    };
  }, [
    demoIndex,
    liveSendFromBank,
    liveBuyTslax,
    ausdBalanceWei,
    tslaxBalanceWei,
    ausdDecimals,
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
        tslaxBalanceWei={tslaxBalanceWei}
        ausdDecimals={ausdDecimals}
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
