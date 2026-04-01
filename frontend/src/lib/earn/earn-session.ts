import { isAddress, type Address } from "viem";

const STORAGE_KEY = "xstocks-earn-session-v1";

export type EarnSessionV1 = {
  ownerAddress: string;
  safeAddress: Address;
  relayDepositAddress: Address;
  registeredAt: number;
  usdcDepositTxHash?: `0x${string}`;
  usdcAmountRaw?: string;
  ausdConvertTxHash?: `0x${string}`;
  /** Step 2 credited amount from indexer `amount`, smallest units (6 decimals). */
  ausdConvertAmountRaw?: string;
  /** Step 3: vault / routing tx from indexer (e.g. ERC-4626 shares IN to the safe). */
  earnVaultTxHash?: `0x${string}`;
  /** Step 3 credited yield `amount` from indexer (18 decimals). */
  earnYieldAmountRaw?: string;
};

function parseSession(raw: string | null): EarnSessionV1 | null {
  if (!raw) return null;
  try {
    const j = JSON.parse(raw) as EarnSessionV1;
    if (
      typeof j.ownerAddress !== "string" ||
      typeof j.safeAddress !== "string" ||
      typeof j.relayDepositAddress !== "string" ||
      typeof j.registeredAt !== "number"
    ) {
      return null;
    }
    if (
      !isAddress(j.safeAddress) ||
      !isAddress(j.relayDepositAddress) ||
      !isAddress(j.ownerAddress)
    ) {
      return null;
    }
    return {
      ownerAddress: j.ownerAddress,
      safeAddress: j.safeAddress,
      relayDepositAddress: j.relayDepositAddress,
      registeredAt: j.registeredAt,
      ...(j.usdcDepositTxHash &&
      typeof j.usdcDepositTxHash === "string" &&
      j.usdcDepositTxHash.startsWith("0x")
        ? { usdcDepositTxHash: j.usdcDepositTxHash as `0x${string}` }
        : {}),
      ...(j.usdcAmountRaw && typeof j.usdcAmountRaw === "string"
        ? { usdcAmountRaw: j.usdcAmountRaw }
        : {}),
      ...(j.ausdConvertTxHash &&
      typeof j.ausdConvertTxHash === "string" &&
      j.ausdConvertTxHash.startsWith("0x")
        ? { ausdConvertTxHash: j.ausdConvertTxHash as `0x${string}` }
        : {}),
      ...(j.ausdConvertAmountRaw && typeof j.ausdConvertAmountRaw === "string"
        ? { ausdConvertAmountRaw: j.ausdConvertAmountRaw }
        : {}),
      ...(j.earnVaultTxHash &&
      typeof j.earnVaultTxHash === "string" &&
      j.earnVaultTxHash.startsWith("0x")
        ? { earnVaultTxHash: j.earnVaultTxHash as `0x${string}` }
        : {}),
      ...(j.earnYieldAmountRaw && typeof j.earnYieldAmountRaw === "string"
        ? { earnYieldAmountRaw: j.earnYieldAmountRaw }
        : {}),
    };
  } catch {
    return null;
  }
}

export function loadEarnSession(): EarnSessionV1 | null {
  if (typeof window === "undefined") return null;
  return parseSession(window.localStorage.getItem(STORAGE_KEY));
}

export function saveEarnSession(session: EarnSessionV1): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

export function clearEarnSession(): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(STORAGE_KEY);
}

export function patchEarnSession(partial: Partial<EarnSessionV1>): void {
  const cur = loadEarnSession();
  if (!cur) return;
  saveEarnSession({ ...cur, ...partial });
}
