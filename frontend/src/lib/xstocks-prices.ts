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
