"use client";

import { useMemo, useState } from "react";
import { useOnchainPortfolio } from "@/lib/hooks/use-onchain-portfolio";
import { useVaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";
import { useXstocksPrices } from "@/lib/hooks/use-xstocks-prices";
import type { VaultApyDisplay } from "@/lib/hooks/use-vault-apy-display";
import {
  getTeslaPriceUsd,
  getVaultAprFromPrices,
} from "@/lib/xstocks-prices";
import { useAutoBootstrap } from "@/lib/hooks/use-auto-bootstrap";
import { useEarnFlow } from "@/lib/hooks/use-earn-flow";
import { useOwnFlow } from "@/lib/hooks/use-own-flow";
import { getEnv } from "@/lib/env";
import { AppTopMenu, type AppTopSection } from "@/components/layout/AppTopMenu";
import { EarnPanel } from "./EarnPanel";
import { OwnPanel } from "./OwnPanel";

function chainLabelFromId(chainId: number): string {
  if (chainId === 1) return "Ethereum";
  return `Chain ${chainId}`;
}

export function Dashboard() {
  useAutoBootstrap();
  const earnFlow = useEarnFlow();
  const ownFlow = useOwnFlow();
  const [section, setSection] = useState<AppTopSection>("earn");
  const envChainId = getEnv().chainId;

  const safes = useMemo(() => {
    const list: `0x${string}`[] = [];
    if (earnFlow.earnSafeAddress) list.push(earnFlow.earnSafeAddress);
    if (ownFlow.ownSafeAddress) list.push(ownFlow.ownSafeAddress as `0x${string}`);
    return list;
  }, [earnFlow.earnSafeAddress, ownFlow.ownSafeAddress]);

  const { vaultTotals } = useOnchainPortfolio(safes);
  const morphoApyQuery = useVaultApyDisplay();
  const pricesQuery = useXstocksPrices();

  const tslaxPriceUsd = useMemo(
    () => getTeslaPriceUsd(pricesQuery.data),
    [pricesQuery.data],
  );

  const earnApyDisplay: VaultApyDisplay | undefined = useMemo(() => {
    const fromFeed = getVaultAprFromPrices(
      pricesQuery.data,
      getEnv().morphoVaultAddress,
    );
    if (fromFeed != null) {
      return {
        apyDecimal: fromFeed,
        rewardApyDecimal: null,
        source: "prices",
        error: false,
      };
    }
    return morphoApyQuery.data;
  }, [pricesQuery.data, morphoApyQuery.data]);

  const earnApyLoading =
    earnApyDisplay?.apyDecimal == null &&
    (pricesQuery.isPending || morphoApyQuery.isPending);

  return (
    <div className="relative min-h-full selection:bg-primary/15">
      <AppTopMenu value={section} onValueChange={setSection} />
      <div
        className="mx-auto flex w-full max-w-4xl flex-col gap-8 px-4 py-10 pb-16 sm:px-6 sm:py-14"
      >
        {section === "own" ? (
          <OwnPanel
            headerTslaxQtyWei={ownFlow.headerTslaxQtyWei}
            headerTslaxQtyDecimals={ownFlow.headerTslaxQtyDecimals}
            vaultUnderlyingWei={
              ownFlow.ownSnap?.underlyingFromShares ?? 0n
            }
            ausdBalanceWei={ownFlow.ownSnap?.ausdBalance ?? 0n}
            ausdDecimals={vaultTotals.ausdDecimals}
            tslaxPriceUsd={tslaxPriceUsd}
            tslaxPriceLoading={pricesQuery.isPending}
            sendFromBank={ownFlow.sendFromBank}
            buyTslax={ownFlow.buyTslax}
            teslaDecimals={ownFlow.teslaMeta.decimals}
            bankAmountRaw={ownFlow.bankAmountRaw}
            tslaxAmountRaw={ownFlow.tslaxAmountRaw}
            bankTxHash={ownFlow.bankTxHash}
            tslaxTxHash={ownFlow.tslaxTxHash}
            relayDepositAddress={ownFlow.relayDepositAddress}
            chainLabel={chainLabelFromId(envChainId)}
          />
        ) : (
          <EarnPanel
            heroLive={earnFlow.heroLive}
            vaultAssetsSum={earnFlow.vaultAssetsSum}
            earnBalanceHeaderDecimals={earnFlow.earnBalanceHeaderDecimals}
            ausdDecimals={earnFlow.ausdDecimals}
            apy={earnApyDisplay}
            apyLoading={
              earnApyLoading || earnFlow.portfolioLoading || earnFlow.registerLoading
            }
            ausdBalanceWei={earnFlow.earnSnap?.ausdBalance ?? 0n}
            vaultUnderlyingWei={
              earnFlow.earnSnap?.underlyingFromShares ?? 0n
            }
            relayDepositAddress={earnFlow.relayDepositAddress}
            chainLabel={chainLabelFromId(envChainId)}
            usdcAmountRaw={earnFlow.usdcAmountRaw}
            bankTxHash={earnFlow.bankTxHash}
            convertTxHash={earnFlow.convertTxHash}
            convertAmountRaw={earnFlow.convertAmountRaw}
            earnTxHash={earnFlow.earnTxHash}
            earnYieldAmountRaw={earnFlow.earnYieldAmountRaw}
            registerError={earnFlow.registerError}
            usdcPollError={earnFlow.usdcPollError}
          />
        )}
      </div>
    </div>
  );
}
