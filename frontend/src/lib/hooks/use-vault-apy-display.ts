"use client";

import { useQuery } from "@tanstack/react-query";
import { getEnv } from "@/lib/env";

export type VaultApyDisplay = {
  /** Morpho `avgNetApy` only (0.0421 = 4.21% after UI formatting) */
  apyDecimal: number | null;
  rewardApyDecimal: number | null;
  source: "morpho" | null;
  error: boolean;
};

type MorphoVaultApyResponse = {
  data?: {
    vaultV2ByAddress?: {
      avgNetApy?: number | null;
      avgApy?: number | null;
      rewards?: { supplyApr?: number | null }[] | null;
    } | null;
  };
};

export function useVaultApyDisplay() {
  const env = getEnv();
  const vault = env.morphoVaultAddress;

  return useQuery({
    queryKey: ["morpho-vault-apy", vault, env.chainId],
    enabled: Boolean(vault),
    staleTime: 60_000,
    queryFn: async (): Promise<VaultApyDisplay> => {
      if (!vault) {
        return {
          apyDecimal: null,
          rewardApyDecimal: null,
          source: null,
          error: false,
        };
      }

      const query = `
        query VaultApy($address: String!, $chainId: Int!) {
          vaultV2ByAddress(address: $address, chainId: $chainId) {
            avgNetApy
            avgApy
            rewards {
              supplyApr
            }
          }
        }
      `;

      const variables = {
        address: vault.toLowerCase(),
        chainId: env.chainId,
      };

      const res = await fetch(env.morphoGraphqlUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query,
          variables,
        }),
      });

      if (!res.ok) {
        const bodyText = await res.text().catch(() => "");
        console.warn("[xstocks/morpho-vault-apy] HTTP error", {
          status: res.status,
          statusText: res.statusText,
          body: bodyText.slice(0, 2000),
          url: env.morphoGraphqlUrl,
          variables,
        });
        return {
          apyDecimal: null,
          rewardApyDecimal: null,
          source: null,
          error: true,
        };
      }

      const json = (await res.json()) as MorphoVaultApyResponse & {
        errors?: { message?: string }[];
      };

      console.log("[xstocks/morpho-vault-apy] GraphQL raw response:", json);

      if (json.errors?.length) {
        console.warn("[xstocks/morpho-vault-apy] GraphQL errors:", json.errors);
        return {
          apyDecimal: null,
          rewardApyDecimal: null,
          source: null,
          error: true,
        };
      }
      const v = json.data?.vaultV2ByAddress;
      if (!v) {
        console.log("[xstocks/morpho-vault-apy] No vaultV2ByAddress in data", {
          data: json.data,
          variables,
        });
        return {
          apyDecimal: null,
          rewardApyDecimal: null,
          source: null,
          error: false,
        };
      }

      const net = v.avgNetApy ?? null;
      let rewardSum = 0;
      if (Array.isArray(v.rewards)) {
        for (const r of v.rewards) {
          if (typeof r?.supplyApr === "number") rewardSum += r.supplyApr;
        }
      }

      const parsed = {
        apyDecimal: typeof net === "number" ? net : null,
        rewardApyDecimal: rewardSum > 0 ? rewardSum : null,
        source: typeof net === "number" ? ("morpho" as const) : null,
        error: false,
      };

      console.log("[xstocks/morpho-vault-apy] Parsed for UI:", {
        avgNetApy: v.avgNetApy,
        avgApy: v.avgApy,
        rewardSum,
        parsed,
      });

      return parsed;
    },
  });
}
