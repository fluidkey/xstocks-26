"use client";

import { useMemo, useState } from "react";
import { HeroFlow, type HeroFlowStatuses } from "@/components/hero/HeroFlow";
import { Button } from "@/components/ui/button";
import { EarnBalanceHeader } from "./EarnBalanceHeader";
import { EarnTimeline } from "./EarnTimeline";
import { DepositCard } from "./DepositCard";
import { RoutingCard } from "./RoutingCard";
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
  ausdDecimals: number | null;
  apy: VaultApyDisplay | undefined;
  apyLoading: boolean;
  ausdBalanceWei: bigint;
  vaultUnderlyingWei: bigint;
  depositConfirmed: boolean;
  routingInProgress: boolean;
  routingDone: boolean;
  stealthSafeAddress: string | null;
};

export function EarnPanel({
  heroLive,
  vaultAssetsSum,
  ausdDecimals,
  apy,
  apyLoading,
  ausdBalanceWei,
  vaultUnderlyingWei,
  depositConfirmed,
  routingInProgress,
  routingDone,
  stealthSafeAddress,
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
      <EarnBalanceHeader
        vaultAssetsSum={vaultAssetsSum}
        ausdDecimals={ausdDecimals}
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
      />

      <div className="flex flex-col gap-5">
        <DepositCard
          address={stealthSafeAddress}
          depositConfirmed={depositConfirmed}
        />
        <RoutingCard inProgress={routingInProgress} done={routingDone} />
      </div>

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
