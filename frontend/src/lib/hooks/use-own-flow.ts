"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import type { Address, PublicClient } from "viem";
import { parseAbiItem } from "viem";
import { mainnet } from "wagmi/chains";
import { usePublicClient, useWatchContractEvent } from "wagmi";
import {
  createStealthSafe,
  getAddressTransactions,
  mergeTransactionsByHash,
  pickLatestInboundErc20ByTokenContract,
} from "@/lib/api/xstocks";
import { erc20Abi } from "@/lib/contracts/erc20";
import { erc4626Abi } from "@/lib/contracts/erc4626";
import { getEnv } from "@/lib/env";
import {
  getOwnSigningAccount,
  subscribeOwnDemoKey,
} from "@/lib/demo/local-account";
import {
  clearOwnSession,
  loadOwnSession,
  patchOwnSession,
  saveOwnSession,
  type OwnSessionV1,
} from "@/lib/own/own-session";
import {
  useOnchainPortfolio,
  type PerSafeSnapshot,
} from "@/lib/hooks/use-onchain-portfolio";
import { useXstocksPrices } from "@/lib/hooks/use-xstocks-prices";
import {
  getAusdTokenMetaFromFeed,
  getTeslaTokenMetaFromFeed,
  type FeedTokenMeta,
} from "@/lib/xstocks-prices";
import type { BankStepStatus, TslaxStepStatus } from "@/components/own/OwnFlow";

function useOwnDemoSignerAddress(): `0x${string}` | null {
  return useSyncExternalStore(
    subscribeOwnDemoKey,
    () => getOwnSigningAccount()?.address ?? null,
    () => null,
  );
}

function addressesEqual(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function pickUsdcInboundToRelay(
  txs: Awaited<ReturnType<typeof getAddressTransactions>>,
  usdc: `0x${string}` | undefined,
  relayLower: string,
): { txHash: `0x${string}`; amount: bigint } | null {
  if (!usdc) return null;
  const usdcL = usdc.toLowerCase();
  for (const t of txs) {
    if (t.type !== "ERC20_TRANSFER" || t.direction !== "IN") continue;
    if ((t.tokenContract ?? "").toLowerCase() !== usdcL) continue;
    if (!t.txHash?.startsWith("0x")) continue;
    if (t.to && relayLower && t.to.toLowerCase() !== relayLower) continue;
    try {
      const raw = BigInt(t.amount ?? "0");
      if (raw <= 0n) continue;
      return { txHash: t.txHash as `0x${string}`, amount: raw };
    } catch {
      continue;
    }
  }
  return null;
}

function ownRegistrationComplete(s: OwnSessionV1): boolean {
  return Boolean(s.safeAddress && s.relayDepositAddress && s.ownerAddress);
}

const USDC_POLL_MS = 10_000;
const USDC_BOOTSTRAP_BLOCKS = 12_000n;
const USDC_LOG_CHUNK_BLOCKS = 4000n;

const usdcTransferEvent = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

async function getUsdcTransfersToRelay(
  client: PublicClient,
  usdc: `0x${string}`,
  relay: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<
  {
    args: { from: Address; to: Address; value: bigint };
    transactionHash: `0x${string}`;
    blockNumber: bigint;
    logIndex: number;
  }[]
> {
  const acc: {
    args: { from: Address; to: Address; value: bigint };
    transactionHash: `0x${string}`;
    blockNumber: bigint;
    logIndex: number;
  }[] = [];
  let start = fromBlock;
  while (start <= toBlock) {
    const end =
      start + USDC_LOG_CHUNK_BLOCKS - 1n > toBlock
        ? toBlock
        : start + USDC_LOG_CHUNK_BLOCKS - 1n;
    const chunk = await client.getLogs({
      address: usdc,
      event: usdcTransferEvent,
      args: { to: relay },
      fromBlock: start,
      toBlock: end,
    });
    for (const log of chunk) {
      if (
        log.args?.value != null &&
        log.args.value > 0n &&
        log.transactionHash &&
        log.blockNumber != null &&
        log.logIndex != null
      ) {
        acc.push({
          args: log.args as { from: Address; to: Address; value: bigint },
          transactionHash: log.transactionHash,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
        });
      }
    }
    start = end + 1n;
  }
  return acc;
}

export type OwnFlowHookState = {
  /** Backend Safe from POST /address (idUser: "own"); use for portfolio + indexer. */
  ownSafeAddress: Address | null;
  sendFromBank: BankStepStatus;
  buyTslax: TslaxStepStatus;
  relayDepositAddress: `0x${string}` | null;
  ownRegisterLoading: boolean;
  ownRegisterError: string | null;
  bankTxHash: `0x${string}` | null;
  tslaxTxHash: `0x${string}` | null;
  bankAmountRaw: bigint | null;
  tslaxAmountRaw: bigint | null;
  ausdMeta: FeedTokenMeta;
  teslaMeta: FeedTokenMeta;
  ownSnap: PerSafeSnapshot | undefined;
  portfolioLoading: boolean;
  headerTslaxQtyWei: bigint;
  headerTslaxQtyDecimals: number | null;
  usdcPollError: string | null;
};

export function useOwnFlow(): OwnFlowHookState {
  const env = getEnv();
  const publicClient = usePublicClient({ chainId: mainnet.id });
  const signerAddr = useOwnDemoSignerAddress();
  const pricesQuery = useXstocksPrices();
  const entries = pricesQuery.data;

  const ausdMeta = useMemo(
    () => getAusdTokenMetaFromFeed(entries, env.ausdAddress ?? null),
    [entries, env.ausdAddress],
  );
  const teslaMeta = useMemo(
    () => getTeslaTokenMetaFromFeed(entries),
    [entries],
  );

  const [session, setSession] = useState<OwnSessionV1 | null>(null);
  const [ownRegisterLoading, setOwnRegisterLoading] = useState(false);
  const [ownRegisterError, setOwnRegisterError] = useState<string | null>(null);
  const registerInFlightRef = useRef(false);
  const [liveUsdcHash, setLiveUsdcHash] = useState<`0x${string}` | null>(null);
  const [liveUsdcAmount, setLiveUsdcAmount] = useState<bigint | null>(null);
  const [tslaxTxLive, setTslaxTxLive] = useState<`0x${string}` | null>(null);
  const [tslaxAmountLive, setTslaxAmountLive] = useState<bigint | null>(null);
  const [ownMorphoAssetsRaw, setOwnMorphoAssetsRaw] = useState<bigint | null>(
    null,
  );
  const [ownMorphoAssetDecimals, setOwnMorphoAssetDecimals] = useState<
    number | null
  >(null);
  const [usdcPollError, setUsdcPollError] = useState<string | null>(null);
  const usdcNextFromBlock = useRef<bigint | undefined>(undefined);

  const ownIndexerCtxRef = useRef({
    bankDone: false,
    tslaxTxHash: null as `0x${string}` | null,
    tslaxAmountRaw: null as bigint | null,
  });

  useLayoutEffect(() => {
    if (typeof window === "undefined") return;
    const s = loadOwnSession();
    if (signerAddr && s && addressesEqual(s.ownerAddress, signerAddr)) {
      setSession(s);
      if (s.usdcDepositTxHash) setLiveUsdcHash(s.usdcDepositTxHash);
      if (s.usdcAmountRaw) {
        try {
          setLiveUsdcAmount(BigInt(s.usdcAmountRaw));
        } catch {
          /* ignore */
        }
      }
      if (s.tslaxTxHash) setTslaxTxLive(s.tslaxTxHash);
      if (s.tslaxAmountRaw) {
        try {
          setTslaxAmountLive(BigInt(s.tslaxAmountRaw));
        } catch {
          setTslaxAmountLive(null);
        }
      }
      return;
    }
    if (signerAddr && s && !addressesEqual(s.ownerAddress, signerAddr)) {
      clearOwnSession();
      setSession(null);
      setLiveUsdcHash(null);
      setLiveUsdcAmount(null);
      setTslaxTxLive(null);
      setTslaxAmountLive(null);
    }
    if (!signerAddr) {
      setSession(null);
      setLiveUsdcHash(null);
      setLiveUsdcAmount(null);
      setTslaxTxLive(null);
      setTslaxAmountLive(null);
    }
  }, [signerAddr]);

  useEffect(() => {
    if (!signerAddr) return;
    let cancelled = false;
    const run = async () => {
      const existing = loadOwnSession();
      if (
        existing &&
        addressesEqual(existing.ownerAddress, signerAddr) &&
        ownRegistrationComplete(existing)
      ) {
        if (!cancelled) setSession(existing);
        return;
      }
      if (registerInFlightRef.current) return;
      registerInFlightRef.current = true;
      setOwnRegisterLoading(true);
      setOwnRegisterError(null);
      try {
        const res = await createStealthSafe({
          idUser: "own",
          ownerAddress: signerAddr,
        });
        if (!res.relayDepositAddress) {
          throw new Error("Missing relayDepositAddress");
        }
        const next: OwnSessionV1 = {
          ownerAddress: signerAddr,
          safeAddress: res.safeAddress as Address,
          relayDepositAddress: res.relayDepositAddress as Address,
          registeredAt: Date.now(),
        };
        if (cancelled) return;
        saveOwnSession(next);
        setSession(next);
      } catch (e) {
        if (!cancelled) {
          setOwnRegisterError(
            e instanceof Error ? e.message : "Own registration failed",
          );
        }
      } finally {
        registerInFlightRef.current = false;
        if (!cancelled) setOwnRegisterLoading(false);
      }
    };
    void run();
    return () => {
      cancelled = true;
      registerInFlightRef.current = false;
    };
  }, [signerAddr]);

  const bankTxHash = liveUsdcHash ?? session?.usdcDepositTxHash ?? null;
  const bankAmountRaw =
    liveUsdcAmount ??
    (session?.usdcAmountRaw ? BigInt(session.usdcAmountRaw) : null);
  const tslaxTxHash = tslaxTxLive ?? session?.tslaxTxHash ?? null;
  const tslaxAmountRaw =
    tslaxAmountLive ??
    (session?.tslaxAmountRaw
      ? (() => {
          try {
            return BigInt(session.tslaxAmountRaw);
          } catch {
            return null;
          }
        })()
      : null);

  const relay = session?.relayDepositAddress;
  const ownSafe = session?.safeAddress ?? null;
  const ownSafes = useMemo(
    () => (ownSafe ? [ownSafe as `0x${string}`] : []),
    [ownSafe],
  );

  const { perSafe, vaultTotals, isLoading: portfolioLoading } =
    useOnchainPortfolio(ownSafes);

  const ownSnap = perSafe[0];

  const ausdOnSafe =
    ownSnap?.ausdBalance != null && ownSnap.ausdBalance > 0n;
  const bankDone = Boolean(bankTxHash) || ausdOnSafe;
  const underlyingFromMorpho =
    ownSnap?.underlyingFromShares != null &&
    ownSnap.underlyingFromShares > 0n;
  const tslaxDone =
    underlyingFromMorpho ||
    Boolean(tslaxTxHash) ||
    (ownMorphoAssetsRaw != null && ownMorphoAssetsRaw > 0n);

  ownIndexerCtxRef.current = {
    bankDone,
    tslaxTxHash,
    tslaxAmountRaw,
  };

  useEffect(() => {
    if (!session || !liveUsdcHash || liveUsdcAmount == null) return;
    patchOwnSession({
      usdcDepositTxHash: liveUsdcHash,
      usdcAmountRaw: liveUsdcAmount.toString(),
    });
    setSession((cur) =>
      cur && addressesEqual(cur.ownerAddress, session.ownerAddress)
        ? {
            ...cur,
            usdcDepositTxHash: liveUsdcHash,
            usdcAmountRaw: liveUsdcAmount.toString(),
          }
        : cur,
    );
  }, [session, liveUsdcHash, liveUsdcAmount]);

  useEffect(() => {
    if (!session || !tslaxTxLive) return;
    patchOwnSession({
      tslaxTxHash: tslaxTxLive,
      ...(tslaxAmountLive != null
        ? { tslaxAmountRaw: tslaxAmountLive.toString() }
        : {}),
    });
    setSession((cur) =>
      cur && addressesEqual(cur.ownerAddress, session.ownerAddress)
        ? {
            ...cur,
            tslaxTxHash: tslaxTxLive,
            ...(tslaxAmountLive != null
              ? { tslaxAmountRaw: tslaxAmountLive.toString() }
              : {}),
          }
        : cur,
    );
  }, [session, tslaxTxLive, tslaxAmountLive]);

  const onUsdcLogs = useCallback((logs: readonly unknown[]) => {
    const log = logs[0] as
      | {
          args?: { value?: bigint };
          transactionHash?: `0x${string}`;
        }
      | undefined;
    if (!log?.args || typeof log.args !== "object" || !("value" in log.args)) {
      return;
    }
    const v = log.args.value as bigint | undefined;
    if (v == null) return;
    setLiveUsdcAmount(v);
    const h = log.transactionHash;
    if (h && typeof h === "string" && h.startsWith("0x")) {
      setLiveUsdcHash(h as `0x${string}`);
    }
  }, []);

  useWatchContractEvent({
    address: env.usdcAddress,
    abi: erc20Abi,
    eventName: "Transfer",
    args: relay ? { to: relay } : undefined,
    chainId: mainnet.id,
    enabled: Boolean(
      env.usdcAddress && relay && session && !bankDone,
    ),
    onLogs: onUsdcLogs,
  });

  useEffect(() => {
    if (!publicClient || !env.usdcAddress || !relay || bankDone) return;
    usdcNextFromBlock.current = undefined;
    let cancelled = false;

    const applyLog = (log: {
      args?: { value?: bigint };
      transactionHash?: `0x${string}`;
    }) => {
      const v = log.args?.value;
      const h = log.transactionHash;
      if (v == null || v <= 0n || !h || !h.startsWith("0x")) return;
      setLiveUsdcAmount(v);
      setLiveUsdcHash(h as `0x${string}`);
    };

    const tick = async () => {
      const relayL = relay.toLowerCase();
      let found = false;
      try {
        const latest = await publicClient.getBlockNumber();
        let from = usdcNextFromBlock.current;
        if (from === undefined) {
          from =
            latest > USDC_BOOTSTRAP_BLOCKS
              ? latest - USDC_BOOTSTRAP_BLOCKS
              : 0n;
        }
        if (from <= latest) {
          const incoming = await getUsdcTransfersToRelay(
            publicClient,
            env.usdcAddress!,
            relay,
            from,
            latest,
          );
          if (cancelled) return;
          if (incoming.length > 0) {
            let pick = incoming[0]!;
            for (let i = 1; i < incoming.length; i++) {
              const log = incoming[i]!;
              if (
                log.blockNumber > pick.blockNumber ||
                (log.blockNumber === pick.blockNumber &&
                  log.logIndex > pick.logIndex)
              ) {
                pick = log;
              }
            }
            applyLog(pick);
            found = true;
          }
          usdcNextFromBlock.current = latest + 1n;
        }
        setUsdcPollError(null);
      } catch (e) {
        const msg =
          e instanceof Error ? e.message : "getContractEvents failed";
        if (process.env.NODE_ENV === "development") {
          console.warn("[own] USDC log poll:", msg);
        }
        setUsdcPollError(msg);
      }

      if (found || cancelled) return;
      try {
        const apiHit = pickUsdcInboundToRelay(
          await getAddressTransactions(relay),
          env.usdcAddress,
          relayL,
        );
        if (cancelled) return;
        if (apiHit) {
          setLiveUsdcAmount(apiHit.amount);
          setLiveUsdcHash(apiHit.txHash);
          setUsdcPollError(null);
        }
      } catch (e) {
        const msg =
          e instanceof Error ? e.message : "relay tx API poll failed";
        if (process.env.NODE_ENV === "development") {
          console.warn("[own] USDC API poll (relay):", msg);
        }
        setUsdcPollError((prev) => prev ?? msg);
      }
    };

    void tick();
    const id = window.setInterval(tick, USDC_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [publicClient, env.usdcAddress, relay, bankDone]);

  useEffect(() => {
    const morphoVault = env.morphoVaultAddress;
    if (!ownSafe || !publicClient || !morphoVault) {
      setOwnMorphoAssetsRaw(null);
      setOwnMorphoAssetDecimals(null);
      return;
    }

    let cancelled = false;
    const tick = async () => {
      try {
        const shares = await publicClient.readContract({
          address: morphoVault,
          abi: erc4626Abi,
          functionName: "balanceOf",
          args: [ownSafe],
        });
        if (cancelled) return;
        const sh = shares as bigint;
        if (sh === 0n) {
          setOwnMorphoAssetsRaw(0n);
          setOwnMorphoAssetDecimals(null);
          return;
        }
        const assets = await publicClient.readContract({
          address: morphoVault,
          abi: erc4626Abi,
          functionName: "convertToAssets",
          args: [sh],
        });
        const assetToken = await publicClient.readContract({
          address: morphoVault,
          abi: erc4626Abi,
          functionName: "asset",
        });
        const dec = await publicClient.readContract({
          address: assetToken,
          abi: erc20Abi,
          functionName: "decimals",
        });
        if (!cancelled) {
          setOwnMorphoAssetsRaw(assets as bigint);
          setOwnMorphoAssetDecimals(Number(dec));
        }
      } catch {
        if (!cancelled) {
          setOwnMorphoAssetsRaw(null);
          setOwnMorphoAssetDecimals(null);
        }
      }
    };

    void tick();
    const id = window.setInterval(tick, 12_000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [publicClient, ownSafe, env.morphoVaultAddress]);

  const shouldPollOwnIndexer = Boolean(
    ownSafe &&
      relay &&
      bankDone &&
      (!tslaxTxHash || tslaxAmountRaw == null),
  );

  useEffect(() => {
    if (!ownSafe || !relay || !shouldPollOwnIndexer) return;
    let cancelled = false;
    const tick = async () => {
      if (!ownSafe || cancelled) return;
      const ctx = ownIndexerCtxRef.current;
      const needTslax =
        ctx.bankDone &&
        (!ctx.tslaxTxHash || ctx.tslaxAmountRaw == null);
      if (!needTslax) return;
      try {
        const safeList = await getAddressTransactions(ownSafe);
        const relayList = await getAddressTransactions(relay);
        if (cancelled) return;
        const merged = mergeTransactionsByHash([safeList, relayList]);
        const hit = pickLatestInboundErc20ByTokenContract(
          merged,
          teslaMeta.address,
          { requireErc20Transfer: true },
        );
        if (hit) {
          setTslaxTxLive((h) => h ?? hit.txHash);
          setTslaxAmountLive((a) => a ?? hit.amountRaw);
        }
      } catch {
        /* indexer/network */
      }
    };
    void tick();
    const id = window.setInterval(tick, 8_000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [shouldPollOwnIndexer, ownSafe, relay, teslaMeta.address]);

  useEffect(() => {
    if (!ownSafe || !relay || shouldPollOwnIndexer || !bankDone) return;
    let cancelled = false;
    const hydrate = async () => {
      try {
        const safeList = await getAddressTransactions(ownSafe);
        const relayList = await getAddressTransactions(relay);
        if (cancelled) return;
        const merged = mergeTransactionsByHash([safeList, relayList]);
        const tslaxHit = pickLatestInboundErc20ByTokenContract(
          merged,
          teslaMeta.address,
          { requireErc20Transfer: true },
        );
        if (tslaxHit) {
          setTslaxTxLive((h) => h ?? tslaxHit.txHash);
          setTslaxAmountLive((a) => a ?? tslaxHit.amountRaw);
        }
      } catch {
        /* indexer/network */
      }
    };
    void hydrate();
    return () => {
      cancelled = true;
    };
  }, [ownSafe, relay, shouldPollOwnIndexer, bankDone, teslaMeta.address]);

  const sendFromBank: BankStepStatus = bankDone ? "completed" : "pending";
  const buyTslax: TslaxStepStatus = !bankDone
    ? "pending"
    : tslaxDone
      ? "completed"
      : "processing";

  const headerTslaxQtyWei = useMemo(() => {
    if (ownMorphoAssetsRaw != null && ownMorphoAssetsRaw > 0n) {
      return ownMorphoAssetsRaw;
    }
    const snapU = ownSnap?.underlyingFromShares ?? 0n;
    if (snapU > 0n) return snapU;
    const idx = tslaxAmountRaw ?? 0n;
    if (idx > 0n) return idx;
    return 0n;
  }, [ownMorphoAssetsRaw, ownSnap?.underlyingFromShares, tslaxAmountRaw]);

  const headerTslaxQtyDecimals = useMemo(() => {
    if (ownMorphoAssetsRaw != null && ownMorphoAssetsRaw > 0n) {
      return ownMorphoAssetDecimals ?? vaultTotals.ausdDecimals;
    }
    const snapU = ownSnap?.underlyingFromShares ?? 0n;
    if (snapU > 0n) return vaultTotals.ausdDecimals;
    if ((tslaxAmountRaw ?? 0n) > 0n) return teslaMeta.decimals;
    return vaultTotals.ausdDecimals;
  }, [
    ownMorphoAssetsRaw,
    ownMorphoAssetDecimals,
    ownSnap?.underlyingFromShares,
    vaultTotals.ausdDecimals,
    tslaxAmountRaw,
    teslaMeta.decimals,
  ]);

  return {
    ownSafeAddress: ownSafe,
    sendFromBank,
    buyTslax,
    relayDepositAddress: relay ? (relay as `0x${string}`) : null,
    ownRegisterLoading,
    ownRegisterError,
    bankTxHash,
    tslaxTxHash,
    bankAmountRaw,
    tslaxAmountRaw,
    ausdMeta,
    teslaMeta,
    ownSnap,
    portfolioLoading: portfolioLoading || ownRegisterLoading,
    headerTslaxQtyWei,
    headerTslaxQtyDecimals,
    usdcPollError,
  };
}
