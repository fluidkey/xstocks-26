import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

const s3 = new S3Client({});

const TOKEN_ADDRESSES = [
  '0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48',
  '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
];

const CHAIN = 'ETHEREUM';
const API_BASE = 'https://chainpro.xyz/api/tokens';

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

export async function handler() {
  const addresses = TOKEN_ADDRESSES.map(a => `${a}:${CHAIN}`).join(',');
  const url = `${API_BASE}?addresses=${addresses}`;

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`API request failed: ${res.status} ${await res.text()}`);
  }

  const data: TokenResponse = await res.json();

  const prices = data.tokens.map(t => ({
    tokenAddress: t.address,
    name: t.name,
    decimals: t.decimals,
    icon: t.logoUri,
    priceUsd: t.priceData.priceUsd,
  }));

  await s3.send(new PutObjectCommand({
    Bucket: process.env.PRICES_BUCKET!,
    Key: 'prices.json',
    Body: JSON.stringify(prices),
    ContentType: 'application/json',
  }));

  console.log('Prices saved:', JSON.stringify(prices));
  return { statusCode: 200, body: 'OK' };
}
