"use client";

import { useQuery } from "@tanstack/react-query";
import type { XstocksPriceEntry } from "@/lib/xstocks-prices";
import { XSTOCKS_PRICES_JSON_URL } from "@/lib/xstocks-prices";

function pricesUrl(): string {
  return (
    process.env.NEXT_PUBLIC_PRICES_JSON_URL?.trim() || XSTOCKS_PRICES_JSON_URL
  );
}

export function useXstocksPrices() {
  const url = pricesUrl();

  return useQuery({
    queryKey: ["xstocks-prices", url],
    staleTime: 60_000,
    queryFn: async (): Promise<XstocksPriceEntry[]> => {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) {
        throw new Error(`prices.json HTTP ${res.status}`);
      }
      const data = (await res.json()) as unknown;
      if (!Array.isArray(data)) {
        throw new Error("prices.json: expected array");
      }
      return data as XstocksPriceEntry[];
    },
  });
}
