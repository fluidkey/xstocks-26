"use client";

import { Sparkles, TrendingUp } from "lucide-react";
import { formatTokenAmount } from "@/lib/hooks/use-onchain-portfolio";
import type { VaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
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

export function EarningStrip({
  vaultAssetsSum,
  ausdDecimals,
  apy,
  apyLoading,
}: Props) {
  const usd = formatTokenAmount(vaultAssetsSum, ausdDecimals, 2);
  const net = apy?.apyDecimal ?? null;

  return (
    <Card className="relative overflow-hidden border-primary/15 bg-gradient-to-br from-card via-card to-primary/[0.06] shadow-sm ring-1 ring-primary/10 transition-shadow hover:shadow-md">
      <div
        className="pointer-events-none absolute -right-8 -top-8 size-32 rounded-full bg-primary/[0.07] blur-2xl"
        aria-hidden
      />
      <CardHeader className="relative flex-row items-center justify-between space-y-0 pb-2">
        <div className="flex items-center gap-2">
          <span className="flex size-9 items-center justify-center rounded-lg bg-primary/10 text-primary">
            <Sparkles className="size-4" strokeWidth={1.75} />
          </span>
          <div>
            <CardTitle className="text-base font-semibold">Vault balance</CardTitle>
            <CardDescription className="text-xs">
              Total across your stealth Safes
            </CardDescription>
          </div>
        </div>
        <Badge variant="secondary" className="font-normal tabular-nums">
          <TrendingUp className="size-3 opacity-70" />
          Live
        </Badge>
      </CardHeader>
      <CardContent className="relative">
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1.5">
          <p className="text-2xl font-semibold tracking-tight text-foreground tabular-nums sm:text-3xl">
            <span className="text-muted-foreground text-lg font-medium sm:text-xl">
              $
            </span>
            {usd}
          </p>
          {apyLoading ? (
            <Skeleton className="h-8 w-36 rounded-md sm:h-9" />
          ) : (
            <p className="text-xl font-semibold tracking-tight text-primary tabular-nums sm:text-2xl">
              earning {formatApyPercent(net)}
            </p>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
