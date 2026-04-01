import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

const s3 = new S3Client({});

const TOKEN_ADDRESSES = [
  '0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48',
  '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
];

const CHAIN = 'ETHEREUM';
const API_BASE = 'https://chainpro.xyz/api/tokens';
const MERKL_VAULT_ADDRESS = '0x32401B9fb79065Bc15949DE0BD43927492f02F0C';
const MERKL_API_BASE = 'https://api.merkl.xyz/v4/opportunities';

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

export async function handler() {
  // Fetch token prices
  const addresses = TOKEN_ADDRESSES.map(a => `${a}:${CHAIN}`).join(',');
  const url = `${API_BASE}?addresses=${addresses}`;

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`API request failed: ${res.status} ${await res.text()}`);
  }

  const data: TokenResponse = await res.json() as TokenResponse;

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

  // Add pool token with price 0 for now (will compute from assets/shares later)
  prices.push({
    tokenAddress: MERKL_VAULT_ADDRESS,
    name: 'Flowdesk AUSD RWA Strategy V2',
    decimals: 18,
    icon: 'https://storage.googleapis.com/merkl-static-assets/protocols/morpho.svg',
    priceUsd: '0',
    aprCumulated,
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
