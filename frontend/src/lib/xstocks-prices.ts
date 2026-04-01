/**
 * xStocks demo price + vault APY feed (S3 JSON).
 * @see https://xstocks2026-pricesbucket7bd6c8de-20gavwamlmay.s3.eu-west-1.amazonaws.com/prices.json
 */

export const XSTOCKS_PRICES_JSON_URL =
  "https://xstocks2026-pricesbucket7bd6c8de-20gavwamlmay.s3.eu-west-1.amazonaws.com/prices.json";

/** Tesla xStock from the feed (priceUsd ≈ spot in USD per share token). */
export const TESLA_XSTOCK_TOKEN_ADDRESS =
  "0x8aD3c73F833d3F9A523aB01476625F269aEB7Cf0";

export type XstocksPriceEntry = {
  tokenAddress: string;
  name: string;
  decimals: number;
  icon: string;
  priceUsd: string;
  /** Cumulative APR / APY style figure from feed (often ~6–7 = 6–7%). */
  aprCumulated?: number;
  aprNative?: number;
};

export function normalizeAddr(a: string): string {
  return a.trim().toLowerCase();
}

export function findPriceEntryByAddress(
  entries: XstocksPriceEntry[],
  address: string,
): XstocksPriceEntry | undefined {
  const key = normalizeAddr(address);
  return entries.find((e) => normalizeAddr(e.tokenAddress) === key);
}

export function getTeslaPriceUsd(
  entries: XstocksPriceEntry[] | undefined,
): number | null {
  if (!entries?.length) return null;
  const byAddr = findPriceEntryByAddress(entries, TESLA_XSTOCK_TOKEN_ADDRESS);
  const row =
    byAddr ??
    entries.find((e) => e.name.toLowerCase().includes("tesla"));
  const n = row ? Number.parseFloat(row.priceUsd) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** `aprCumulated` from feed for the Morpho vault token (percent points, e.g. 6.67). */
export function getVaultAprFromPrices(
  entries: XstocksPriceEntry[] | undefined,
  vaultAddress: string | undefined,
): number | null {
  if (!entries?.length || !vaultAddress) return null;
  const row = findPriceEntryByAddress(entries, vaultAddress);
  const v = row?.aprCumulated;
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  return v;
}

/** Canonical AUSD in the deployed feed (matches `EARN_STEP2_TOKEN_CONTRACT`). */
const FEED_FALLBACK_AUSD =
  "0x00000000efe302beaa2b3e6e1b18d08d69a9012a" as const;

export type FeedTokenMeta = {
  address: `0x${string}`;
  decimals: number;
};

/**
 * Resolve AUSD address + decimals from the price feed, falling back to env / defaults.
 */
export function getAusdTokenMetaFromFeed(
  entries: XstocksPriceEntry[] | undefined,
  fallbackAddress?: string | null,
): FeedTokenMeta {
  const fb = fallbackAddress?.trim().toLowerCase();
  if (entries?.length) {
    if (fb) {
      const byEnv = findPriceEntryByAddress(entries, fb);
      if (byEnv) {
        return {
          address: normalizeAddr(byEnv.tokenAddress) as `0x${string}`,
          decimals: byEnv.decimals,
        };
      }
    }
    const byName =
      entries.find(
        (e) =>
          e.name.trim().toLowerCase() === "ausd" ||
          (e.name.toLowerCase().includes("ausd") &&
            !e.name.toLowerCase().includes("strategy") &&
            !e.name.toLowerCase().includes("wrapper")),
      ) ?? findPriceEntryByAddress(entries, FEED_FALLBACK_AUSD);
    if (byName) {
      return {
        address: normalizeAddr(byName.tokenAddress) as `0x${string}`,
        decimals: byName.decimals,
      };
    }
  }
  if (fb && fb.startsWith("0x") && fb.length === 42) {
    return { address: fb as `0x${string}`, decimals: 6 };
  }
  return {
    address: normalizeAddr(FEED_FALLBACK_AUSD) as `0x${string}`,
    decimals: 6,
  };
}

/**
 * Tesla xStock address + decimals from the feed (fallback: {@link TESLA_XSTOCK_TOKEN_ADDRESS}, 18).
 */
export function getTeslaTokenMetaFromFeed(
  entries: XstocksPriceEntry[] | undefined,
): FeedTokenMeta {
  if (entries?.length) {
    const row =
      findPriceEntryByAddress(entries, TESLA_XSTOCK_TOKEN_ADDRESS) ??
      entries.find((e) => e.name.toLowerCase().includes("tesla"));
    if (row) {
      return {
        address: normalizeAddr(row.tokenAddress) as `0x${string}`,
        decimals: row.decimals,
      };
    }
  }
  return {
    address: normalizeAddr(TESLA_XSTOCK_TOKEN_ADDRESS) as `0x${string}`,
    decimals: 18,
  };
}

/**
 * Morpho / “RWA strategy” vault token row when present (18-decimal vault shares in feed).
 */
export function getMorphoVaultMetaFromFeed(
  entries: XstocksPriceEntry[] | undefined,
  fallbackVaultAddress?: string | null,
): FeedTokenMeta | null {
  const fb = fallbackVaultAddress?.trim();
  if (entries?.length && fb) {
    const row = findPriceEntryByAddress(entries, fb);
    if (row) {
      return {
        address: normalizeAddr(row.tokenAddress) as `0x${string}`,
        decimals: row.decimals,
      };
    }
  }
  if (fb?.startsWith("0x") && fb.length === 42) {
    return { address: normalizeAddr(fb) as `0x${string}`, decimals: 18 };
  }
  return null;
}

/** Vault wrapper fAUSDe row when listed (Earn step-3 yield token). */
export function getVaultWrapperMetaFromFeed(
  entries: XstocksPriceEntry[] | undefined,
  fallbackWrapperAddress?: string | null,
): FeedTokenMeta | null {
  if (entries?.length) {
    const byWrapperName = entries.find((e) =>
      e.name.toLowerCase().includes("vault wrapper"),
    );
    if (byWrapperName) {
      return {
        address: normalizeAddr(byWrapperName.tokenAddress) as `0x${string}`,
        decimals: byWrapperName.decimals,
      };
    }
  }
  const fb = fallbackWrapperAddress?.trim();
  if (fb && entries?.length) {
    const row = findPriceEntryByAddress(entries, fb);
    if (row) {
      return {
        address: normalizeAddr(row.tokenAddress) as `0x${string}`,
        decimals: row.decimals,
      };
    }
  }
  if (fb?.startsWith("0x") && fb.length === 42) {
    return { address: normalizeAddr(fb) as `0x${string}`, decimals: 18 };
  }
  return null;
}
