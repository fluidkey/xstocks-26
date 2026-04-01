"use client";

import { useEffect, useMemo, useState } from "react";
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
import type {
  DepositFlowStatus,
  TriStateFlowStatus,
} from "@/components/hero/HeroFlow";
import { AppTopMenu, type AppTopSection } from "@/components/layout/AppTopMenu";
import { EarnPanel } from "./EarnPanel";
import { OwnPanel } from "./OwnPanel";

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
  const [section, setSection] = useState<AppTopSection>("earn");

  const safes = useMemo(
    () => accounts.map((a) => a.stealthSafeAddress),
    [accounts],
  );
  const { perSafe, aggregated, vaultTotals, isLoading: portfolioLoading } =
    useOnchainPortfolio(safes);
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

  const heroDeposit: DepositFlowStatus = depositConfirmed
    ? "completed"
    : "not_started";
  const heroConvert: TriStateFlowStatus = !depositConfirmed
    ? "not_started"
    : routingDone
      ? "completed"
      : "processing";
  const heroEarn: TriStateFlowStatus = !routingDone
    ? "not_started"
    : portfolioLoading || aggregated.vaultAssetsSum === 0n
      ? "processing"
      : "completed";

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
      <AppTopMenu value={section} onValueChange={setSection} />
      <div
        className="mx-auto flex w-full max-w-4xl flex-col gap-8 px-4 py-10 pb-16 sm:px-6 sm:py-14"
      >
        {section === "own" ? (
          <OwnPanel
            tslaxBalanceWei={activeSnap?.underlyingFromShares ?? 0n}
            ausdBalanceWei={activeSnap?.ausdBalance ?? 0n}
            ausdDecimals={vaultTotals.ausdDecimals}
            sendFromBank={depositConfirmed ? "completed" : "pending"}
            buyTslax={
              !depositConfirmed
                ? "pending"
                : routingDone
                  ? "completed"
                  : "processing"
            }
          />
        ) : (
          <EarnPanel
            heroLive={{
              deposit: heroDeposit,
              convert: heroConvert,
              earn: heroEarn,
            }}
            vaultAssetsSum={aggregated.vaultAssetsSum}
            ausdDecimals={vaultTotals.ausdDecimals}
            apy={apyQuery.data}
            apyLoading={apyQuery.isLoading}
            ausdBalanceWei={activeSnap?.ausdBalance ?? 0n}
            vaultUnderlyingWei={activeSnap?.underlyingFromShares ?? 0n}
            depositConfirmed={depositConfirmed}
            routingInProgress={routingInProgress}
            routingDone={routingDone}
            stealthSafeAddress={activeAccount?.stealthSafeAddress ?? null}
          />
        )}
      </div>
    </div>
  );
}
