"use client";

import { useEffect, useMemo } from "react";
import { useStealthAccounts } from "@/lib/demo/stealth-accounts-context";
import { useOnchainPortfolio } from "@/lib/hooks/use-onchain-portfolio";
import { useVaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";
import { useAutoBootstrap } from "@/lib/hooks/use-auto-bootstrap";
import {
  getSigningAccount,
  getStoredDemoPrivateKey,
} from "@/lib/demo/local-account";
import { generateStealthSafeForNonce } from "@/lib/stealth/generate-stealth-safe";
import { registerStealthAccount } from "@/lib/api/client";
import { getEnv } from "@/lib/env";
import { EarningStrip } from "./EarningStrip";
import { DepositCard } from "./DepositCard";
import { RoutingCard } from "./RoutingCard";
import { Separator } from "@/components/ui/separator";

const rotatedVaultCycleIds = new Set<string>();

function nextNonceFromAccounts(
  accounts: { nonce: string }[],
): bigint {
  let max = -1n;
  for (const a of accounts) {
    try {
      const n = BigInt(a.nonce);
      if (n > max) max = n;
    } catch {
      /* ignore */
    }
  }
  return max < 0n ? 0n : max + 1n;
}

export function Dashboard() {
  useAutoBootstrap();
  const { accounts, activeAccount, addAccount } = useStealthAccounts();

  const safes = useMemo(
    () => accounts.map((a) => a.stealthSafeAddress),
    [accounts],
  );
  const { perSafe, aggregated, vaultTotals } = useOnchainPortfolio(safes);
  const apyQuery = useVaultApyDisplay();

  const activeSnap = useMemo(() => {
    if (!activeAccount) return undefined;
    return perSafe.find(
      (p) =>
        p.safe.toLowerCase() === activeAccount.stealthSafeAddress.toLowerCase(),
    );
  }, [perSafe, activeAccount]);

  const depositConfirmed =
    activeSnap?.ausdBalance != null && activeSnap.ausdBalance > 0n;
  const routingDone =
    activeSnap?.underlyingFromShares != null &&
    activeSnap.underlyingFromShares > 0n;
  const routingInProgress = depositConfirmed && !routingDone;

  useEffect(() => {
    if (!activeAccount || !routingDone) return;
    if (rotatedVaultCycleIds.has(activeAccount.id)) return;
    rotatedVaultCycleIds.add(activeAccount.id);

    const pk = getStoredDemoPrivateKey();
    const signer = getSigningAccount();
    if (!pk || !signer) {
      rotatedVaultCycleIds.delete(activeAccount.id);
      return;
    }

    void (async () => {
      try {
        const nonce = nextNonceFromAccounts(accounts);
        const env = getEnv();
        const gen = await generateStealthSafeForNonce({
          userPrivateKey: pk,
          userPin: env.demoFluidkeyPin,
          userAddress: signer.address,
          nonce,
        });

        addAccount(
          {
            label: "Stealth",
            stealthSafeAddress: gen.stealthSafeAddress,
            stealthOwnerAddresses: gen.stealthOwnerAddresses,
            nonce: gen.nonce.toString(),
            stealthPrivateKey: gen.stealthPrivateKey,
          },
          { setAsActive: true },
        );

        try {
          await registerStealthAccount({
            stealthSafeAddress: gen.stealthSafeAddress,
            stealthOwnerAddresses: gen.stealthOwnerAddresses,
            demoSignerAddress: signer.address,
            nonce: gen.nonce.toString(),
          });
        } catch {
          /* optional */
        }
      } catch {
        rotatedVaultCycleIds.delete(activeAccount.id);
      }
    })();
  }, [
    routingDone,
    activeAccount?.id,
    activeAccount,
    accounts,
    addAccount,
  ]);

  return (
    <div className="relative min-h-full selection:bg-primary/15">
      <div
        className="pointer-events-none fixed inset-0 -z-10 bg-[radial-gradient(ellipse_80%_50%_at_50%_-20%,oklch(0.92_0.06_175/0.35),transparent)]"
        aria-hidden
      />
      <div className="mx-auto flex w-full max-w-lg flex-col gap-8 px-4 py-12 sm:px-6 sm:py-16">
        <header className="space-y-1">
          <h1 className="text-balance text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
            xStocks auto-earn
          </h1>
          <Separator className="mt-6 max-w-12 rounded-full bg-primary/40" />
        </header>

        <EarningStrip
          vaultAssetsSum={aggregated.vaultAssetsSum}
          ausdDecimals={vaultTotals.ausdDecimals}
          apy={apyQuery.data}
          apyLoading={apyQuery.isLoading}
        />

        <div className="flex flex-col gap-5">
          <DepositCard
            address={activeAccount?.stealthSafeAddress ?? null}
            depositConfirmed={depositConfirmed}
          />
          <RoutingCard inProgress={routingInProgress} done={routingDone} />
        </div>
      </div>
    </div>
  );
}
