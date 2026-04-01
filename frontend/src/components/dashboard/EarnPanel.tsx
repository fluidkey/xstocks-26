"use client";

import {
  HeroFlow,
  type HeroFlowStatuses,
} from "@/components/hero/HeroFlow";
import { EarnBalanceHeader } from "./EarnBalanceHeader";
import { EarnTimeline } from "./EarnTimeline";
import type { VaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";

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

      <HeroFlow {...heroLive} />

      <EarnTimeline
        deposit={heroLive.deposit}
        convert={heroLive.convert}
        earn={heroLive.earn}
        ausdBalanceWei={ausdBalanceWei}
        vaultUnderlyingWei={vaultUnderlyingWei}
        ausdDecimals={ausdDecimals}
        relayDepositAddress={relayDepositAddress ?? null}
        chainLabel={chainLabel}
        usdcAmountRaw={usdcAmountRaw}
        bankTxHash={bankTxHash}
        convertTxHash={convertTxHash}
        convertAmountRaw={convertAmountRaw}
        earnTxHash={earnTxHash}
        earnYieldAmountRaw={earnYieldAmountRaw}
      />
    </div>
  );
}
