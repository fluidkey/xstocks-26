import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { createPublicClient, http, parseAbi } from 'viem';
import { mainnet } from 'viem/chains';

const s3 = new S3Client({});

const UNDERLYING_TOKEN = '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a';
const TOKEN_ADDRESSES = [
  '0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48',
  UNDERLYING_TOKEN,
];

const CHAIN = 'ETHEREUM';
const API_BASE = 'https://chainpro.xyz/api/tokens';
const MERKL_VAULT_ADDRESS = '0x32401B9fb79065Bc15949DE0BD43927492f02F0C';
const MERKL_API_BASE = 'https://api.merkl.xyz/v4/opportunities';
const VAULT_WRAPPER_TOKEN = '0x727f8c82b9c210362bee141a1f26c24ebe7beaa5';

// Alchemy API key read from SSM in other lambdas, but here we hardcode the RPC
// since fetch-prices doesn't have SSM access and this is a public read
const ALCHEMY_RPC = 'https://eth-mainnet.g.alchemy.com/v2/dLKA3jNT503x4C6tzPeOgPrZ1YprJh-r';

const erc4626Abi = parseAbi([
  'function convertToAssets(uint256 shares) view returns (uint256)',
  'function decimals() view returns (uint8)',
]);

interface TokenResponse {
  tokens: Array<{
    address: string;
    name: string;
    decimals: number;
    logoUri: string;
    priceData: {
      priceUsd: string;
    };
  }>;
}

interface MerklOpportunity {
  apr: number;
  nativeAprRecord?: {
    value: number;
  };
}

/**
 * Computes the price of an ERC4626 vault token based on its asset-to-share ratio
 * and the underlying token price.
 *
 * price = (convertToAssets(10^vaultDecimals) * underlyingPrice * 10^vaultDecimals) / (10^underlyingDecimals)
 */
async function computeVaultTokenPrice(
  publicClient: ReturnType<typeof createPublicClient>,
  vaultAddress: `0x${string}`,
  underlyingPriceUsd: number,
  underlyingDecimals: number,
): Promise<string> {
  const vaultDecimals = await publicClient.readContract({
    abi: erc4626Abi,
    address: vaultAddress,
    functionName: 'decimals',
  });

  const oneShare = BigInt(10) ** BigInt(vaultDecimals);

  // How many underlying assets does 1 full share represent?
  const assetsPerShare = await publicClient.readContract({
    abi: erc4626Abi,
    address: vaultAddress,
    functionName: 'convertToAssets',
    args: [oneShare],
  });

  // ratio = assetsPerShare / 10^underlyingDecimals
  const ratio = Number(assetsPerShare) / Math.pow(10, underlyingDecimals);
  const price = ratio * underlyingPriceUsd;

  return price.toString();
}

export async function handler() {
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(ALCHEMY_RPC),
  });

  // Fetch token prices
  const addresses = TOKEN_ADDRESSES.map(a => `${a}:${CHAIN}`).join(',');
  const url = `${API_BASE}?addresses=${addresses}`;

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`API request failed: ${res.status} ${await res.text()}`);
  }

  const data: TokenResponse = await res.json() as TokenResponse;

  // Get the underlying token price (AUSD)
  const underlyingToken = data.tokens.find(
    t => t.address.toLowerCase() === UNDERLYING_TOKEN.toLowerCase(),
  );
  const underlyingPriceUsd = underlyingToken ? parseFloat(underlyingToken.priceData.priceUsd) : 1;
  const underlyingDecimals = underlyingToken?.decimals ?? 6;

  // Compute vault and wrapper prices on-chain
  const [vaultPrice, wrapperPrice] = await Promise.all([
    computeVaultTokenPrice(publicClient, MERKL_VAULT_ADDRESS as `0x${string}`, underlyingPriceUsd, underlyingDecimals),
    computeVaultTokenPrice(publicClient, VAULT_WRAPPER_TOKEN as `0x${string}`, underlyingPriceUsd, underlyingDecimals),
  ]);

  // Fetch pool APR from Merkl
  let aprCumulated: number | undefined;
  let aprNative: number | undefined;
  try {
    const merklUrl = `${MERKL_API_BASE}?chainId=1&explorerAddress=${MERKL_VAULT_ADDRESS}`;
    const merklRes = await fetch(merklUrl);
    if (merklRes.ok) {
      const merklData = await merklRes.json() as MerklOpportunity[];
      if (merklData.length > 0) {
        aprCumulated = merklData[0].apr;
        aprNative = merklData[0].nativeAprRecord?.value;
      }
    }
  } catch (err) {
    console.warn('Failed to fetch Merkl APR:', err);
  }

  const prices = data.tokens.map(t => ({
    tokenAddress: t.address,
    name: t.name,
    decimals: t.decimals,
    icon: t.logoUri,
    priceUsd: t.priceData.priceUsd,
    aprCumulated: undefined as number | undefined,
    aprNative: undefined as number | undefined,
  }));

  // Add vault token
  prices.push({
    tokenAddress: MERKL_VAULT_ADDRESS,
    name: 'Flowdesk AUSD RWA Strategy V2',
    decimals: 18,
    icon: 'https://storage.googleapis.com/merkl-static-assets/protocols/morpho.svg',
    priceUsd: vaultPrice,
    aprCumulated,
    aprNative,
  });

  // Add wrapper token
  prices.push({
    tokenAddress: VAULT_WRAPPER_TOKEN,
    name: 'Vault Wrapper fAUSDe',
    decimals: 18,
    icon: 'https://storage.googleapis.com/merkl-static-assets/protocols/morpho.svg',
    priceUsd: wrapperPrice,
    aprCumulated: aprCumulated! - 0.5,
    aprNative,
  });

  await s3.send(new PutObjectCommand({
    Bucket: process.env.PRICES_BUCKET!,
    Key: 'prices.json',
    Body: JSON.stringify(prices),
    ContentType: 'application/json',
  }));

  console.log('Prices saved:', JSON.stringify(prices));
  return { statusCode: 200, body: 'OK' };
}
