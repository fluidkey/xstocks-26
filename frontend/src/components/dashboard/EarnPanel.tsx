"use client";

import { useMemo, useState } from "react";
import { HeroFlow, type HeroFlowStatuses } from "@/components/hero/HeroFlow";
import { Button } from "@/components/ui/button";
import { EarnBalanceHeader } from "./EarnBalanceHeader";
import { EarnTimeline } from "./EarnTimeline";
import type { VaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";

const DEMO_STEPS: HeroFlowStatuses[] = [
  {
    deposit: "not_started",
    convert: "not_started",
    earn: "not_started",
  },
  {
    deposit: "completed",
    convert: "not_started",
    earn: "not_started",
  },
  {
    deposit: "completed",
    convert: "processing",
    earn: "not_started",
  },
  {
    deposit: "completed",
    convert: "completed",
    earn: "not_started",
  },
  {
    deposit: "completed",
    convert: "completed",
    earn: "processing",
  },
  {
    deposit: "completed",
    convert: "completed",
    earn: "completed",
  },
];

type Props = {
  heroLive: HeroFlowStatuses;
  vaultAssetsSum: bigint;
  /** Decimals for the hero balance line (ERC-4626 underlying when applicable). */
  earnBalanceHeaderDecimals: number | null;
  ausdDecimals: number | null;
  apy: VaultApyDisplay | undefined;
  apyLoading: boolean;
  ausdBalanceWei: bigint;
  vaultUnderlyingWei: bigint;
  relayDepositAddress?: string | null;
  chainLabel?: string;
  usdcAmountRaw?: bigint | null;
  bankTxHash?: `0x${string}` | null;
  convertTxHash?: `0x${string}` | null;
  convertAmountRaw?: bigint | null;
  earnTxHash?: `0x${string}` | null;
  earnYieldAmountRaw?: bigint | null;
  registerError?: string | null;
  usdcPollError?: string | null;
};

export function EarnPanel({
  heroLive,
  vaultAssetsSum,
  earnBalanceHeaderDecimals,
  ausdDecimals,
  apy,
  apyLoading,
  ausdBalanceWei,
  vaultUnderlyingWei,
  relayDepositAddress,
  chainLabel,
  usdcAmountRaw,
  bankTxHash,
  convertTxHash,
  convertAmountRaw,
  earnTxHash,
  earnYieldAmountRaw,
  registerError,
  usdcPollError,
}: Props) {
  const [demoIndex, setDemoIndex] = useState<number | null>(null);

  const heroStatuses: HeroFlowStatuses = useMemo(() => {
    const step = demoIndex !== null ? DEMO_STEPS[demoIndex] : null;
    return step ?? heroLive;
  }, [demoIndex, heroLive]);

  function advanceDemo() {
    setDemoIndex((i) => {
      if (i === null) return 0;
      if (i < DEMO_STEPS.length - 1) return i + 1;
      return null;
    });
  }

  return (
    <div className="flex w-full flex-col gap-10">
      {registerError ? (
        <p className="text-center text-sm text-destructive">{registerError}</p>
      ) : null}
      {usdcPollError ? (
        <p className="text-center text-xs text-amber-700 dark:text-amber-400">
          USDC detection: {usdcPollError}
        </p>
      ) : null}

      <EarnBalanceHeader
        vaultAssetsSum={vaultAssetsSum}
        ausdDecimals={earnBalanceHeaderDecimals ?? ausdDecimals}
        apy={apy}
        apyLoading={apyLoading}
      />

      <HeroFlow {...heroStatuses} />

      <EarnTimeline
        deposit={heroStatuses.deposit}
        convert={heroStatuses.convert}
        earn={heroStatuses.earn}
        ausdBalanceWei={ausdBalanceWei}
        vaultUnderlyingWei={vaultUnderlyingWei}
        ausdDecimals={ausdDecimals}
        relayDepositAddress={
          demoIndex !== null ? null : (relayDepositAddress ?? null)
        }
        chainLabel={chainLabel}
        usdcAmountRaw={demoIndex !== null ? null : usdcAmountRaw}
        bankTxHash={demoIndex !== null ? null : bankTxHash}
        convertTxHash={demoIndex !== null ? null : convertTxHash}
        convertAmountRaw={demoIndex !== null ? null : convertAmountRaw}
        earnTxHash={demoIndex !== null ? null : earnTxHash}
        earnYieldAmountRaw={demoIndex !== null ? null : earnYieldAmountRaw}
      />

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
