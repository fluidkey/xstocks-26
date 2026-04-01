import { isAddress, type Address } from "viem";

const STORAGE_KEY = "xstocks-own-session-v1";

/** Single Own-tab session: backend Safe + paired relay from POST /address (idUser: "own"). */
export type OwnSessionV1 = {
  ownerAddress: string;
  safeAddress: Address;
  relayDepositAddress: Address;
  registeredAt: number;
  usdcDepositTxHash?: `0x${string}`;
  usdcAmountRaw?: string;
  /** TSLAx IN on safe (indexer), step 2. */
  tslaxTxHash?: `0x${string}`;
  tslaxAmountRaw?: string;
};

function parseSession(raw: string | null): OwnSessionV1 | null {
  if (!raw) return null;
  try {
    const j = JSON.parse(raw) as OwnSessionV1;
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
      ...(j.tslaxTxHash &&
      typeof j.tslaxTxHash === "string" &&
      j.tslaxTxHash.startsWith("0x")
        ? { tslaxTxHash: j.tslaxTxHash as `0x${string}` }
        : {}),
      ...(j.tslaxAmountRaw && typeof j.tslaxAmountRaw === "string"
        ? { tslaxAmountRaw: j.tslaxAmountRaw }
        : {}),
    };
  } catch {
    return null;
  }
}

export function loadOwnSession(): OwnSessionV1 | null {
  if (typeof window === "undefined") return null;
  return parseSession(window.localStorage.getItem(STORAGE_KEY));
}

export function saveOwnSession(session: OwnSessionV1): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(session));
}

export function clearOwnSession(): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(STORAGE_KEY);
}

export function patchOwnSession(partial: Partial<OwnSessionV1>): void {
  const cur = loadOwnSession();
  if (!cur) return;
  saveOwnSession({ ...cur, ...partial });
}
