"use client";

import type { HeroFlowStatuses } from "@/components/hero/HeroFlow";
import {
  createStealthSafe,
  EARN_STEP3_YIELD_TOKEN_CONTRACT,
  getAddressTransactions,
  mergeTransactionsByHash,
  pickEarnStep2ConversionTx,
  pickEarnStep3YieldTx,
} from "@/lib/api/xstocks";
import { erc20Abi } from "@/lib/contracts/erc20";
import { erc4626Abi } from "@/lib/contracts/erc4626";
import {
  getEarnSigningAccount,
  subscribeEarnDemoKey,
} from "@/lib/demo/local-account";
import {
  clearEarnSession,
  loadEarnSession,
  patchEarnSession,
  saveEarnSession,
  type EarnSessionV1,
} from "@/lib/earn/earn-session";
import { getEnv } from "@/lib/env";
import { useOnchainPortfolio, type PerSafeSnapshot } from "@/lib/hooks/use-onchain-portfolio";
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
import { usePublicClient, useWatchContractEvent } from "wagmi";
import { mainnet } from "wagmi/chains";

function useEarnDemoSignerAddress(): `0x${string}` | null {
  return useSyncExternalStore(
    subscribeEarnDemoKey,
    () => getEarnSigningAccount()?.address ?? null,
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

export type EarnFlowState = {
  heroLive: HeroFlowStatuses;
  earnSafeAddress: Address | null;
  relayDepositAddress: Address | null;
  registerLoading: boolean;
  registerError: string | null;
  bankTxHash: `0x${string}` | null;
  convertTxHash: `0x${string}` | null;
  /** Step 2 credited amount from indexer `amount` (6 decimals). */
  convertAmountRaw: bigint | null;
  /** Vault / routing step tx hash from indexer when available. */
  earnTxHash: `0x${string}` | null;
  /** Step 3 yield `amount` from indexer (18 decimals); drives “Earning yield on $X”. */
  earnYieldAmountRaw: bigint | null;
  usdcAmountRaw: bigint | null;
  /** Morpho vault assets when >0; else yield-token position in AUSD raw units; else indexed convert amount. */
  vaultAssetsSum: bigint;
  /** Decimals for formatting {@link vaultAssetsSum} in the earn balance header (vault underlying vs AUSD). */
  earnBalanceHeaderDecimals: number | null;
  ausdDecimals: number | null;
  earnSnap: PerSafeSnapshot | undefined;
  portfolioLoading: boolean;
  /** Last on-chain USDC poll failure (e.g. RPC log range); empty when OK. */
  usdcPollError: string | null;
};

const USDC_POLL_MS = 10_000;
/** First poll scans this many recent blocks so a deposit just before load is still found. */
const USDC_BOOTSTRAP_BLOCKS = 12_000n;
/** Alchemy limits responses when fetching all USDC Transfers; chunk + filter `to` in RPC. */
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

export function useEarnFlow(): EarnFlowState {
  const env = getEnv();
  /**
   * Wagmi is configured for `mainnet` only (`wagmi.ts`). Requesting a client for
   * `NEXT_PUBLIC_CHAIN_ID` when that is not 1 yields `undefined` and USDC polling never runs.
   */
  const publicClient = usePublicClient({ chainId: mainnet.id });
  const signerAddr = useEarnDemoSignerAddress();
  const [session, setSession] = useState<EarnSessionV1 | null>(null);
  const [registerLoading, setRegisterLoading] = useState(false);
  const [registerError, setRegisterError] = useState<string | null>(null);
  const registerInFlightRef = useRef(false);
  const [liveUsdcHash, setLiveUsdcHash] = useState<`0x${string}` | null>(null);
  const [liveUsdcAmount, setLiveUsdcAmount] = useState<bigint | null>(null);
  const [ausdTxHash, setAusdTxHash] = useState<`0x${string}` | null>(null);
  const [ausdConvertAmountRaw, setAusdConvertAmountRaw] = useState<
    bigint | null
  >(null);
  const [earnVaultTxHash, setEarnVaultTxHash] = useState<`0x${string}` | null>(
    null,
  );
  const [earnYieldAmountLive, setEarnYieldAmountLive] = useState<
    bigint | null
  >(null);
  /** ERC-4626 vault shares for {@link EARN_STEP3_YIELD_TOKEN_CONTRACT} on the earn Safe. */
  const [yieldTokenBalance, setYieldTokenBalance] = useState<bigint | null>(
    null,
  );
  /** `convertToAssets(shares)` from that vault — underlying token raw (USD stable when asset is AUSD). */
  const [earnYieldVaultAssetsRaw, setEarnYieldVaultAssetsRaw] = useState<
    bigint | null
  >(null);
  const [earnVaultUnderlyingDecimals, setEarnVaultUnderlyingDecimals] =
    useState<number | null>(null);
  const [usdcPollError, setUsdcPollError] = useState<string | null>(null);
  const usdcNextFromBlock = useRef<bigint | undefined>(undefined);
  const chainIdMismatchWarned = useRef(false);
  /** Fresh flags for indexer poll ticks (interval closures must not read stale React state). */
  const earnIndexerCtxRef = useRef({
    depositDone: false,
    convertTxHash: null as `0x${string}` | null,
    convertAmountRaw: null as bigint | null,
    convertDone: false,
    earnTxHash: null as `0x${string}` | null,
    earnYieldAmountRaw: null as bigint | null,
  });

  useLayoutEffect(() => {
    if (typeof window === "undefined") return;
    const s = loadEarnSession();
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
      if (s.ausdConvertTxHash) setAusdTxHash(s.ausdConvertTxHash);
      if (s.ausdConvertAmountRaw) {
        try {
          setAusdConvertAmountRaw(BigInt(s.ausdConvertAmountRaw));
        } catch {
          setAusdConvertAmountRaw(null);
        }
      }
      if (s.earnVaultTxHash) setEarnVaultTxHash(s.earnVaultTxHash);
      if (s.earnYieldAmountRaw) {
        try {
          setEarnYieldAmountLive(BigInt(s.earnYieldAmountRaw));
        } catch {
          setEarnYieldAmountLive(null);
        }
      }
      return;
    }
    if (signerAddr && s && !addressesEqual(s.ownerAddress, signerAddr)) {
      clearEarnSession();
      setSession(null);
      setLiveUsdcHash(null);
      setLiveUsdcAmount(null);
      setAusdTxHash(null);
      setAusdConvertAmountRaw(null);
      setEarnVaultTxHash(null);
      setEarnYieldAmountLive(null);
      setYieldTokenBalance(null);
      setEarnYieldVaultAssetsRaw(null);
      setEarnVaultUnderlyingDecimals(null);
    }
  }, [signerAddr]);

  useEffect(() => {
    if (!signerAddr) return;
    let cancelled = false;
    const run = async () => {
      const existing = loadEarnSession();
      if (existing && addressesEqual(existing.ownerAddress, signerAddr)) {
        if (!cancelled) setSession(existing);
        return;
      }
      if (registerInFlightRef.current) return;
      registerInFlightRef.current = true;
      setRegisterLoading(true);
      setRegisterError(null);
      try {
        const res = await createStealthSafe({
          idUser: "earn",
          ownerAddress: signerAddr,
        });
        if (!res.relayDepositAddress) {
          throw new Error("Missing relayDepositAddress");
        }
        const next: EarnSessionV1 = {
          ownerAddress: signerAddr,
          safeAddress: res.safeAddress as Address,
          relayDepositAddress: res.relayDepositAddress as Address,
          registeredAt: Date.now(),
        };
        if (cancelled) return;
        saveEarnSession(next);
        setSession(next);
      } catch (e) {
        if (!cancelled) {
          setRegisterError(
            e instanceof Error ? e.message : "Registration failed",
          );
        }
      } finally {
        registerInFlightRef.current = false;
        if (!cancelled) setRegisterLoading(false);
      }
    };
    void run();
    return () => {
      cancelled = true;
      registerInFlightRef.current = false;
    };
  }, [signerAddr]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (env.chainId !== mainnet.id && !chainIdMismatchWarned.current) {
      chainIdMismatchWarned.current = true;
      console.warn(
        `[earn] NEXT_PUBLIC_CHAIN_ID=${env.chainId} but wagmi only configures Ethereum mainnet (${mainnet.id}). USDC watches use mainnet; set CHAIN_ID to 1 or extend wagmi.ts with your chain.`,
      );
    }
  }, [env.chainId]);

  const bankTxHash =
    liveUsdcHash ?? session?.usdcDepositTxHash ?? null;
  const usdcAmountRaw =
    liveUsdcAmount ??
    (session?.usdcAmountRaw ? BigInt(session.usdcAmountRaw) : null);
  const convertTxHash =
    ausdTxHash ?? session?.ausdConvertTxHash ?? null;
  const convertAmountRaw =
    ausdConvertAmountRaw ??
    (session?.ausdConvertAmountRaw
      ? (() => {
          try {
            return BigInt(session.ausdConvertAmountRaw);
          } catch {
            return null;
          }
        })()
      : null);
  const earnTxHash =
    earnVaultTxHash ?? session?.earnVaultTxHash ?? null;
  const earnYieldAmountRaw =
    earnYieldAmountLive ??
    (session?.earnYieldAmountRaw
      ? (() => {
          try {
            return BigInt(session.earnYieldAmountRaw);
          } catch {
            return null;
          }
        })()
      : null);

  const relay = session?.relayDepositAddress;
  const earnSafe = session?.safeAddress ?? null;
  const earnSafes = useMemo(
    () => (earnSafe ? [earnSafe as `0x${string}`] : []),
    [earnSafe],
  );

  const { perSafe, aggregated, vaultTotals, isLoading: portfolioLoading } =
    useOnchainPortfolio(earnSafes);

  const earnSnap = perSafe[0];

  const ausdOnSafe =
    earnSnap?.ausdBalance != null && earnSnap.ausdBalance > 0n;
  const convertDone = Boolean(convertTxHash) || ausdOnSafe;

  const depositDone = Boolean(bankTxHash);

  earnIndexerCtxRef.current = {
    depositDone,
    convertTxHash,
    convertAmountRaw,
    convertDone,
    earnTxHash,
    earnYieldAmountRaw,
  };

  /**
   * Earn yield vault (ERC-4626): shares `balanceOf(safe)` then `convertToAssets(shares)`
   * for header USD (underlying raw units; format with `ausdDecimals` when asset is AUSD).
   */
  useEffect(() => {
    if (!earnSafe) {
      setYieldTokenBalance(null);
      setEarnYieldVaultAssetsRaw(null);
      setEarnVaultUnderlyingDecimals(null);
      return;
    }
    if (!publicClient) return;

    let cancelled = false;
    const tick = async () => {
      try {
        const shares = await publicClient.readContract({
          address: EARN_STEP3_YIELD_TOKEN_CONTRACT,
          abi: erc4626Abi,
          functionName: "balanceOf",
          args: [earnSafe],
        });
        if (cancelled) return;
        setYieldTokenBalance(shares as bigint);
        if (shares === 0n) {
          setEarnYieldVaultAssetsRaw(0n);
          setEarnVaultUnderlyingDecimals(null);
          return;
        }
        const assets = await publicClient.readContract({
          address: EARN_STEP3_YIELD_TOKEN_CONTRACT,
          abi: erc4626Abi,
          functionName: "convertToAssets",
          args: [shares],
        });
        const assetToken = await publicClient.readContract({
          address: EARN_STEP3_YIELD_TOKEN_CONTRACT,
          abi: erc4626Abi,
          functionName: "asset",
        });
        const dec = await publicClient.readContract({
          address: assetToken,
          abi: erc20Abi,
          functionName: "decimals",
        });
        if (!cancelled) {
          setEarnYieldVaultAssetsRaw(assets as bigint);
          setEarnVaultUnderlyingDecimals(Number(dec));
        }
      } catch {
        if (!cancelled) {
          setYieldTokenBalance(null);
          setEarnYieldVaultAssetsRaw(null);
          setEarnVaultUnderlyingDecimals(null);
        }
      }
    };

    void tick();
    const id = window.setInterval(tick, 12_000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [publicClient, earnSafe]);

  useEffect(() => {
    if (!session || !liveUsdcHash || liveUsdcAmount == null) return;
    patchEarnSession({
      usdcDepositTxHash: liveUsdcHash,
      usdcAmountRaw: liveUsdcAmount.toString(),
    });
  }, [session, liveUsdcHash, liveUsdcAmount]);

  useEffect(() => {
    if (!session || !ausdTxHash) return;
    patchEarnSession({
      ausdConvertTxHash: ausdTxHash,
      ...(ausdConvertAmountRaw != null
        ? { ausdConvertAmountRaw: ausdConvertAmountRaw.toString() }
        : {}),
    });
  }, [session, ausdTxHash, ausdConvertAmountRaw]);

  useEffect(() => {
    if (!session || !earnVaultTxHash) return;
    patchEarnSession({
      earnVaultTxHash: earnVaultTxHash,
      ...(earnYieldAmountLive != null
        ? { earnYieldAmountRaw: earnYieldAmountLive.toString() }
        : {}),
    });
  }, [session, earnVaultTxHash, earnYieldAmountLive]);

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
      env.usdcAddress && relay && session && !depositDone,
    ),
    onLogs: onUsdcLogs,
  });

  useEffect(() => {
    if (!publicClient || !env.usdcAddress || !relay || depositDone) return;
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
          console.warn("[earn] USDC log poll:", msg);
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
          console.warn("[earn] USDC API poll (relay):", msg);
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
  }, [publicClient, env.usdcAddress, relay, depositDone]);

  const shouldPollEarnIndexer = Boolean(
    earnSafe &&
      depositDone &&
      (!convertTxHash ||
        convertAmountRaw == null ||
        (convertDone &&
          (!earnTxHash || earnYieldAmountRaw == null))),
  );

  useEffect(() => {
    if (!earnSafe || !shouldPollEarnIndexer) return;
    let cancelled = false;
    const tick = async () => {
      if (!earnSafe || cancelled) return;
      const ctx = earnIndexerCtxRef.current;
      if (!ctx.depositDone) return;
      const needAusd =
        !ctx.convertTxHash || ctx.convertAmountRaw == null;
      const needVault =
        ctx.convertDone &&
        (!ctx.earnTxHash || ctx.earnYieldAmountRaw == null);
      if (!needAusd && !needVault) return;
      try {
        const safeList = await getAddressTransactions(earnSafe);
        const relayList = relay
          ? await getAddressTransactions(relay)
          : [];
        if (cancelled) return;
        const merged = mergeTransactionsByHash([safeList, relayList]);

        if (needAusd) {
          const hit2 = pickEarnStep2ConversionTx(merged);
          if (hit2) {
            setAusdTxHash((h) => h ?? hit2.txHash);
            setAusdConvertAmountRaw((a) => a ?? hit2.amountRaw);
          }
        }
        if (needVault) {
          const hit3 = pickEarnStep3YieldTx(merged);
          if (hit3) {
            setEarnVaultTxHash((h) => h ?? hit3.txHash);
            setEarnYieldAmountLive((a) => a ?? hit3.amountRaw);
          }
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
  }, [shouldPollEarnIndexer, earnSafe, relay]);

  /** When idle polling is off (flow looks complete), still sync indexer tx data once on load/refresh. */
  useEffect(() => {
    if (!earnSafe || !depositDone || shouldPollEarnIndexer) return;
    let cancelled = false;
    const hydrate = async () => {
      try {
        const safeList = await getAddressTransactions(earnSafe);
        const relayList = relay
          ? await getAddressTransactions(relay)
          : [];
        if (cancelled) return;
        const merged = mergeTransactionsByHash([safeList, relayList]);
        const hit2 = pickEarnStep2ConversionTx(merged);
        if (hit2) {
          setAusdTxHash((h) => h ?? hit2.txHash);
          setAusdConvertAmountRaw((a) => a ?? hit2.amountRaw);
        }
        const hit3 = pickEarnStep3YieldTx(merged);
        if (hit3) {
          setEarnVaultTxHash((h) => h ?? hit3.txHash);
          setEarnYieldAmountLive((a) => a ?? hit3.amountRaw);
        }
      } catch {
        /* indexer/network */
      }
    };
    void hydrate();
    return () => {
      cancelled = true;
    };
  }, [earnSafe, relay, depositDone, shouldPollEarnIndexer]);

  const routingDone =
    (earnSnap?.underlyingFromShares != null &&
      earnSnap.underlyingFromShares > 0n) ||
    Boolean(earnTxHash) ||
    (yieldTokenBalance != null && yieldTokenBalance > 0n);

  const earnYieldAusdRawFromIndexer =
    earnYieldAmountRaw != null && earnYieldAmountRaw > 0n
      ? earnYieldAmountRaw / 10n ** 18n
      : 0n;

  const vaultAssetsSumDisplay =
    earnYieldVaultAssetsRaw != null && earnYieldVaultAssetsRaw > 0n
      ? earnYieldVaultAssetsRaw
      : aggregated.vaultAssetsSum > 0n
        ? aggregated.vaultAssetsSum
        : earnYieldAusdRawFromIndexer > 0n
          ? earnYieldAusdRawFromIndexer
          : convertAmountRaw ?? 0n;

  const earnBalanceHeaderDecimals =
    earnYieldVaultAssetsRaw != null &&
    earnYieldVaultAssetsRaw > 0n &&
    earnVaultUnderlyingDecimals != null
      ? earnVaultUnderlyingDecimals
      : vaultTotals.ausdDecimals;

  const heroLive: HeroFlowStatuses = useMemo(() => {
    if (!depositDone) {
      return {
        deposit: "not_started",
        convert: "not_started",
        earn: "not_started",
      };
    }
    if (!convertDone) {
      return {
        deposit: "completed",
        convert: "processing",
        earn: "not_started",
      };
    }
    if (!routingDone) {
      return {
        deposit: "completed",
        convert: "completed",
        earn: "processing",
      };
    }
    return {
      deposit: "completed",
      convert: "completed",
      earn: "completed",
    };
  }, [depositDone, convertDone, routingDone]);

  return {
    heroLive,
    earnSafeAddress: earnSafe,
    relayDepositAddress: relay ?? null,
    registerLoading,
    registerError,
    bankTxHash,
    convertTxHash,
    convertAmountRaw,
    earnTxHash,
    earnYieldAmountRaw,
    usdcAmountRaw,
    vaultAssetsSum: vaultAssetsSumDisplay,
    earnBalanceHeaderDecimals,
    ausdDecimals: vaultTotals.ausdDecimals,
    earnSnap,
    portfolioLoading: portfolioLoading || registerLoading,
    usdcPollError,
  };
}
