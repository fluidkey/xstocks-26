"use client";

import { formatTokenAmount } from "@/lib/hooks/use-onchain-portfolio";
import type { VaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";
import { Skeleton } from "@/components/ui/skeleton";

type Props = {
  vaultAssetsSum: bigint;
  ausdDecimals: number | null;
  apy: VaultApyDisplay | undefined;
  apyLoading: boolean;
};

function formatApyPercent(d: number | null): string {
  if (d == null) return "—";
  const pct = d > 1 ? d : d * 100;
  return `${pct.toFixed(2)}%`;
}

export function EarnBalanceHeader({
  vaultAssetsSum,
  ausdDecimals,
  apy,
  apyLoading,
}: Props) {
  const usd = formatTokenAmount(vaultAssetsSum, ausdDecimals, 2);
  const net = apy?.apyDecimal ?? null;

  return (
    <header className="flex w-full flex-col items-center text-center">
      <p className="text-balance text-4xl font-semibold tabular-nums tracking-tight text-primary/85 sm:text-5xl">
        <span className="text-3xl font-semibold sm:text-4xl">$</span>
        {usd}
      </p>
      {apyLoading ? (
        <Skeleton className="mt-2 h-7 w-36 rounded-md sm:h-8 sm:w-40" />
      ) : (
        <p className="mt-2 text-xl font-medium tabular-nums tracking-tight text-muted-foreground sm:text-2xl">
          earning {formatApyPercent(net)}
        </p>
      )}
    </header>
  );
}
