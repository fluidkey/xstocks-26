/**
 * Public env for the auto-earn demo. Use a dedicated RPC URL in deployment.
 * Optional values omit features (N/A in UI) instead of fabricating data.
 */

export type AppEnv = {
  chainId: number;
  rpcUrl: string | undefined;
  /** xStocks backend (migrate OpenAPI e.g. …/v1). */
  xstocksApiUrl: string;
  usdcAddress: `0x${string}` | undefined;
  ausdAddress: `0x${string}` | undefined;
  morphoVaultAddress: `0x${string}` | undefined;
  morphoGraphqlUrl: string;
  /** Legacy demo env field (unused after removing client stealth generation). */
  demoFluidkeyPin: string;
  backendUrl: string | undefined;
  withdrawBatchAddress: `0x${string}` | undefined;
  safeInitializer: {
    to?: `0x${string}`;
    data?: `0x${string}`;
    fallbackHandler?: `0x${string}`;
  };
};

function parseHexAddress(value: string | undefined): `0x${string}` | undefined {
  if (!value || !value.startsWith("0x") || value.length !== 42) return undefined;
  return value as `0x${string}`;
}

export function getEnv(): AppEnv {
  const raw = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? "1");
  const chainId = Number.isFinite(raw) && raw > 0 ? raw : 1;
  return {
    chainId,
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL || undefined,
    xstocksApiUrl:
      process.env.NEXT_PUBLIC_XSTOCKS_API_URL?.replace(/\/$/, "") ??
      "https://5o381m93aa.execute-api.eu-west-1.amazonaws.com/v1",
    usdcAddress:
      parseHexAddress(process.env.NEXT_PUBLIC_USDC_ADDRESS) ??
      (chainId === 1
        ? ("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" as `0x${string}`)
        : undefined),
    ausdAddress: parseHexAddress(process.env.NEXT_PUBLIC_AUSD_ADDRESS),
    morphoVaultAddress: parseHexAddress(
      process.env.NEXT_PUBLIC_MORPHO_VAULT_ADDRESS ??
        "0x32401b9fb79065bc15949de0bd43927492f02f0c",
    ),
    morphoGraphqlUrl:
      process.env.NEXT_PUBLIC_MORPHO_GRAPHQL_URL?.replace(/\/$/, "") ??
      "https://api.morpho.org/graphql",
    demoFluidkeyPin: process.env.NEXT_PUBLIC_DEMO_FLUIDKEY_PIN ?? "0000",
    backendUrl: process.env.NEXT_PUBLIC_BACKEND_URL || undefined,
    withdrawBatchAddress: parseHexAddress(process.env.NEXT_PUBLIC_WITHDRAW_BATCH_ADDRESS),
    safeInitializer: {
      to: parseHexAddress(process.env.NEXT_PUBLIC_SAFE_INITIALIZER_TO),
      data: process.env.NEXT_PUBLIC_SAFE_INITIALIZER_DATA?.startsWith("0x")
        ? (process.env.NEXT_PUBLIC_SAFE_INITIALIZER_DATA as `0x${string}`)
        : undefined,
      fallbackHandler: parseHexAddress(process.env.NEXT_PUBLIC_SAFE_INITIALIZER_FALLBACK_HANDLER),
    },
  };
}
