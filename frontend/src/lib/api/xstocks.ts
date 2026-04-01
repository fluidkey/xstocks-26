import { getEnv } from "@/lib/env";

/** Earn step 2: indexer must show this ERC-20 as `direction: IN` (see xStocks API). */
export const EARN_STEP2_TOKEN_CONTRACT =
  "0x00000000efe302beaa2b3e6e1b18d08d69a9012a" as const;

/** Raw `amount` on indexer txs for {@link EARN_STEP2_TOKEN_CONTRACT} uses 6 decimals. */
export const EARN_STEP2_TOKEN_DECIMALS = 6;

/**
 * Earn step 3: yield ERC-20 credited to the safe (`direction: IN`).
 * Indexer rows use `tokenContract` for this asset; mints may use `from: 0x0`, not this address.
 */
export const EARN_STEP3_YIELD_TOKEN_CONTRACT =
  "0x9a2ec73c45b5398b6799e960f5d22e1699f2b3cc" as const;

/** Raw `amount` on indexer txs for step-3 yield transfers uses 18 decimals. */
export const EARN_STEP3_YIELD_DECIMALS = 18;

/**
 * Format indexer step-3 `amount` for “$X” UI. Uses 18-decimal raw units; display
 * matches `(raw / 1e18) / 1e6` USD (aligned with AUSD 6-decimal scale in this flow).
 */
export function formatEarnYieldIndexerUsd(amountRaw: bigint): string {
  if (amountRaw <= 0n) return "0";
  const mantissa = amountRaw / 10n ** BigInt(EARN_STEP3_YIELD_DECIMALS);
  const n = Number(mantissa) / 1_000_000;
  return n.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
}

export type IdUser = "own" | "earn";

export type CreateStealthSafeRequestBody = {
  idUser: IdUser;
  ownerAddress: string;
};

export type CreateStealthSafeResponse = {
  safeAddress: string;
  ownerAddress: string;
  deploymentStatus?: "NONE" | "DEPLOYED";
  relayDepositAddress?: string;
};

export type XstocksTransaction = {
  txHash: string;
  blockNumber?: number;
  timestamp?: number;
  from: string;
  to: string;
  amount: string;
  tokenContract: string;
  type: "NATIVE_EXTERNAL" | "NATIVE_INTERNAL" | "ERC20_TRANSFER";
  direction: "IN" | "OUT";
  /** Some backends include a symbol when token contract varies by environment. */
  tokenSymbol?: string;
  /** Backend-specific markers (ignored if absent). */
  conversionComplete?: boolean;
  ausdConversion?: boolean;
  flowStep?: string;
};

/** Dedupe by tx hash and shallow-merge rows (safe + relay may both return the same hash with different fields). */
export function mergeTransactionsByHash(
  lists: XstocksTransaction[][],
): XstocksTransaction[] {
  const map = new Map<string, XstocksTransaction>();
  for (const list of lists) {
    for (const t of list) {
      const h = t.txHash?.toLowerCase();
      if (!h?.startsWith("0x")) continue;
      const prev = map.get(h);
      map.set(h, prev ? { ...prev, ...t } : t);
    }
  }
  return [...map.values()];
}

function apiBase(): string {
  return getEnv().xstocksApiUrl.replace(/\/$/, "");
}

export async function createStealthSafe(
  body: CreateStealthSafeRequestBody,
): Promise<CreateStealthSafeResponse> {
  const res = await fetch(`${apiBase()}/address`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`createStealthSafe failed: ${res.status} ${err}`);
  }
  const json = (await res.json()) as Record<string, unknown>;
  const safeAddress = String(json.safeAddress ?? "");
  const ownerAddress = String(json.ownerAddress ?? "");
  const relayRaw = json.relayDepositAddress ?? json.relaydepositaddress;
  const relayDepositAddress =
    relayRaw != null && typeof relayRaw === "string" ? relayRaw : undefined;
  const deploymentStatus = json.deploymentStatus as
    | CreateStealthSafeResponse["deploymentStatus"]
    | undefined;
  if (!safeAddress.startsWith("0x") || safeAddress.length !== 42) {
    throw new Error("createStealthSafe: invalid safeAddress in response");
  }
  const relayOk =
    relayDepositAddress &&
    relayDepositAddress.startsWith("0x") &&
    relayDepositAddress.length === 42;
  if (!relayOk) {
    throw new Error(
      "createStealthSafe: API response must include relayDepositAddress",
    );
  }
  return {
    safeAddress,
    ownerAddress,
    deploymentStatus,
    ...(relayOk ? { relayDepositAddress } : {}),
  };
}

export type UserAddressRow = {
  address: string;
  addedAt: number;
};

export async function getUserAddresses(
  idUser: string,
): Promise<UserAddressRow[]> {
  const res = await fetch(`${apiBase()}/user/${encodeURIComponent(idUser)}/address`);
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`getUserAddresses failed: ${res.status} ${err}`);
  }
  const json = (await res.json()) as { data?: UserAddressRow[] };
  return Array.isArray(json.data) ? json.data : [];
}

export async function getAddressTransactions(
  address: string,
): Promise<XstocksTransaction[]> {
  const lower = address.toLowerCase();
  const res = await fetch(`${apiBase()}/address/${encodeURIComponent(lower)}/transaction`);
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`getAddressTransactions failed: ${res.status} ${err}`);
  }
  const json = (await res.json()) as { data?: XstocksTransaction[] };
  return Array.isArray(json.data) ? json.data : [];
}

/**
 * Latest inbound ERC-20 credit for `tokenContract` (`direction: IN`, positive `amount`).
 * Earn step 2 historically matched without requiring `type === "ERC20_TRANSFER"`.
 */
export function pickLatestInboundErc20ByTokenContract(
  txs: XstocksTransaction[],
  tokenContract: string,
  options?: { requireErc20Transfer?: boolean },
): { txHash: `0x${string}`; amountRaw: bigint } | null {
  const tokenL = tokenContract.toLowerCase();
  const requireErc20 = options?.requireErc20Transfer ?? false;
  const candidates: { t: XstocksTransaction; amount: bigint }[] = [];
  for (const t of txs) {
    if (!t.txHash?.startsWith("0x")) continue;
    if (requireErc20 && t.type !== "ERC20_TRANSFER") continue;
    if ((t.tokenContract ?? "").toLowerCase() !== tokenL) continue;
    if (t.direction !== "IN") continue;
    let amount: bigint;
    try {
      const raw = (t.amount ?? "").trim();
      if (!raw) continue;
      amount = BigInt(raw);
    } catch {
      continue;
    }
    if (amount <= 0n) continue;
    candidates.push({ t, amount });
  }
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    const tb = Number(b.t.timestamp ?? b.t.blockNumber ?? 0);
    const ta = Number(a.t.timestamp ?? a.t.blockNumber ?? 0);
    return tb - ta;
  });
  const best = candidates[0]!;
  return {
    txHash: best.t.txHash as `0x${string}`,
    amountRaw: best.amount,
  };
}

/** Earn step 2: merged indexer tx with AUSD as IN (see {@link EARN_STEP2_TOKEN_DECIMALS}). */
export function pickEarnStep2ConversionTx(
  txs: XstocksTransaction[],
): { txHash: `0x${string}`; amountRaw: bigint } | null {
  return pickLatestInboundErc20ByTokenContract(
    txs,
    EARN_STEP2_TOKEN_CONTRACT,
    { requireErc20Transfer: false },
  );
}

/** Earn step 3: IN ERC-20 for {@link EARN_STEP3_YIELD_TOKEN_CONTRACT}. */
export function pickEarnStep3YieldTx(
  txs: XstocksTransaction[],
): { txHash: `0x${string}`; amountRaw: bigint } | null {
  return pickLatestInboundErc20ByTokenContract(
    txs,
    EARN_STEP3_YIELD_TOKEN_CONTRACT,
    { requireErc20Transfer: true },
  );
}
