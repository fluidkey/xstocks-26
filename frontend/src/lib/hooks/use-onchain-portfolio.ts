"use client";

import { erc20Abi } from "@/lib/contracts/erc20";
import { erc4626Abi } from "@/lib/contracts/erc4626";
import { getEnv } from "@/lib/env";
import { useMemo } from "react";
import { formatUnits } from "viem";
import type { UseReadContractsReturnType } from "wagmi";
import { useReadContracts } from "wagmi";
import { mainnet } from "wagmi/chains";

export type PerSafeSnapshot = {
  safe: `0x${string}`;
  ausdBalance: bigint | null;
  vaultShares: bigint | null;
  underlyingFromShares: bigint | null;
};

export type VaultTotals = {
  totalAssets: bigint | null;
  totalSupply: bigint | null;
  /** Raw on-chain ratio: assets * 1e18 / totalSupply shares. */
  assetsPerShareRay: bigint | null;
  ausdDecimals: number | null;
};

type ReadRow = NonNullable<
  UseReadContractsReturnType["data"]
>[number];

function resultBigint(row: ReadRow | undefined): bigint | null {
  if (!row || row.status !== "success") return null;
  return row.result as bigint;
}

export function useOnchainPortfolio(safes: `0x${string}`[]) {
  const env = getEnv();
  /** Wagmi config only registers mainnet; `NEXT_PUBLIC_CHAIN_ID` must match for reads to work. */
  const readChainId = mainnet.id;

  const firstContracts = useMemo(() => {
    if (!env.ausdAddress || !env.morphoVaultAddress || safes.length === 0) {
      return [];
    }
    return [
      {
        chainId: readChainId,
        address: env.ausdAddress,
        abi: erc20Abi,
        functionName: "decimals" as const,
      },
      ...safes.flatMap((safe) => [
        {
          chainId: readChainId,
          address: env.ausdAddress,
          abi: erc20Abi,
          functionName: "balanceOf" as const,
          args: [safe] as const,
        },
        {
          chainId: readChainId,
          address: env.morphoVaultAddress,
          abi: erc4626Abi,
          functionName: "balanceOf" as const,
          args: [safe] as const,
        },
      ]),
      {
        chainId: readChainId,
        address: env.morphoVaultAddress,
        abi: erc4626Abi,
        functionName: "totalAssets" as const,
      },
      {
        chainId: readChainId,
        address: env.morphoVaultAddress,
        abi: erc4626Abi,
        functionName: "totalSupply" as const,
      },
    ];
  }, [safes, env.ausdAddress, env.morphoVaultAddress, readChainId]);

  const q1 = useReadContracts({
    contracts: firstContracts,
    query: {
      enabled: firstContracts.length > 0,
      refetchInterval: 12_000,
    },
  });

  const ausdDecimals =
    q1.data?.[0]?.status === "success"
      ? Number(q1.data[0].result as number)
      : null;

  const perSafeAusdAndShares = useMemo(() => {
    const out: { ausd: bigint | null; shares: bigint | null }[] = [];
    for (let i = 0; i < safes.length; i++) {
      const ausdIx = 1 + i * 2;
      const shareIx = 2 + i * 2;
      out.push({
        ausd: resultBigint(q1.data?.[ausdIx]),
        shares: resultBigint(q1.data?.[shareIx]),
      });
    }
    return out;
  }, [q1.data, safes.length]);

  const taIx = 1 + safes.length * 2;
  const tsIx = 2 + safes.length * 2;

  const totalAssets = resultBigint(q1.data?.[taIx]);
  const totalSupply = resultBigint(q1.data?.[tsIx]);

  const vaultTotals: VaultTotals = useMemo(() => {
    let assetsPerShareRay: bigint | null = null;
    if (
      totalAssets != null &&
      totalSupply != null &&
      totalSupply > 0n
    ) {
      assetsPerShareRay = (totalAssets * 10n ** 18n) / totalSupply;
    }
    return {
      totalAssets,
      totalSupply,
      assetsPerShareRay,
      ausdDecimals,
    };
  }, [totalAssets, totalSupply, ausdDecimals]);

  const convertContracts = useMemo(() => {
    if (!env.morphoVaultAddress || safes.length === 0) return [];
    return safes.map((_, i) => {
      const shares = perSafeAusdAndShares[i]?.shares ?? 0n;
      return {
        chainId: readChainId,
        address: env.morphoVaultAddress,
        abi: erc4626Abi,
        functionName: "convertToAssets" as const,
        args: [shares] as const,
      };
    });
  }, [safes, env.morphoVaultAddress, readChainId, perSafeAusdAndShares]);

  const q2 = useReadContracts({
    contracts: convertContracts,
    query: {
      enabled: q1.isSuccess && convertContracts.length > 0,
      refetchInterval: 12_000,
    },
  });

  const perSafe: PerSafeSnapshot[] = useMemo(() => {
    return safes.map((safe, i) => {
      const { ausd, shares } = perSafeAusdAndShares[i] ?? {
        ausd: null,
        shares: null,
      };
      const underlyingFromShares = resultBigint(q2.data?.[i]);
      return {
        safe,
        ausdBalance: ausd,
        vaultShares: shares,
        underlyingFromShares,
      };
    });
  }, [safes, perSafeAusdAndShares, q2.data]);

  const aggregated = useMemo(() => {
    let ausd = 0n;
    let underlying = 0n;
    for (const row of perSafe) {
      if (row.ausdBalance != null) ausd += row.ausdBalance;
      if (row.underlyingFromShares != null) {
        underlying += row.underlyingFromShares;
      }
    }
    return { ausdSum: ausd, vaultAssetsSum: underlying };
  }, [perSafe]);

  return {
    isLoading: q1.isLoading || (convertContracts.length > 0 && q2.isLoading),
    isError: q1.isError,
    perSafe,
    vaultTotals,
    aggregated,
    refetch: () => {
      void q1.refetch();
      void q2.refetch();
    },
  };
}

export function formatTokenAmount(
  value: bigint | null,
  decimals: number | null,
  digits = 4,
): string {
  if (value == null) return "—";
  if (value === 0n) {
    if (decimals == null) return "0.00";
  } else if (decimals == null) {
    return "—";
  }
  return Number(formatUnits(value, decimals)).toLocaleString(undefined, {
    minimumFractionDigits: Math.min(2, digits),
    maximumFractionDigits: digits,
  });
}
