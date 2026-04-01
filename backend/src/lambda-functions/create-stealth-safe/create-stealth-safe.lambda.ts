import Safe from '@safe-global/protocol-kit';
import { getAddress, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { dynamo } from '../_utils/dynamo-client';
import { getInitializerExtraFields } from '../_utils/initializer-extra-fields';
import { getParam } from '../_utils/ssm-params';
import { CreateStealthSafeRequest } from './types';

const ALCHEMY_API_URL = 'https://dashboard.alchemy.com/api/graphql/variables';

async function createVariable(authToken: string, variableName: string, items: string[]) {
  const url = `${ALCHEMY_API_URL}/${variableName}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Alchemy-Token': authToken,
    },
    body: JSON.stringify({ items }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Failed to create ${variableName}: ${res.status} ${body}`);
  }
}

export async function handler(event: {
  body?: string;
  isBase64Encoded?: boolean;
}) {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
    : event.body ?? '';

  let request: CreateStealthSafeRequest;
  try {
    request = JSON.parse(rawBody);
  } catch {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  if (!request.idUser || !request.ownerAddress) {
    return { statusCode: 400, body: JSON.stringify({ error: 'idUser and ownerAddress are required' }) };
  }

  const { idUser, ownerAddress } = request;

  // 1. Read secrets from SSM
  const [relayerPrivateKey, alchemyApiKey, alchemyAuthToken] = await Promise.all([
    getParam('/xstocks/relayer'),
    getParam('/xstocks/alchemy-api-key'),
    getParam('/xstocks/alchemy-auth-token'),
  ]);
  const relayerAccount = privateKeyToAccount(relayerPrivateKey as `0x${string}`);
  const providerUrl = `https://eth-mainnet.g.alchemy.com/v2/${alchemyApiKey}`;

  // 2. Get initializer extra fields (enables AutoEarn module during deployment)
  const initializerExtra = getInitializerExtraFields();

  // 3. Predict the safe address (no on-chain tx yet)

  const protocolKit = await Safe.init({
    provider: providerUrl,
    signer: relayerPrivateKey,
    predictedSafe: {
      safeAccountConfig: {
        owners: [relayerAccount.address],
        threshold: 1,
        to: initializerExtra.to,
        data: initializerExtra.data,
      },
      safeDeploymentConfig: {
        saltNonce: toHex(0),
        safeVersion: '1.3.0',
      },
    },
  });

  const safeAddress = await protocolKit.getAddress();
  console.log('Predicted safe address:', safeAddress);

  // 4. Store stealth safe info in DynamoDB
  await dynamo.put({
    TableName: 'xstocks-user-address',
    Item: {
      idUser,
      address: safeAddress.toLowerCase(),
      safeAddress: safeAddress.toLowerCase(),
      ownerAddress: ownerAddress.toLowerCase(),
      deploymentStatus: 'NONE',
      saltNonce: toHex(0),
      initializerExtraTo: initializerExtra.to,
      initializerExtraData: initializerExtra.data,
      createdAt: Math.floor(Date.now() / 1000),
    },
  });
  console.log('Stealth safe stored in DynamoDB');

  // 5. Track the predicted safe address for transactions via Alchemy
  const checksummedAddress = getAddress(safeAddress);
  await createVariable(alchemyAuthToken, 'trackedAddresses', [checksummedAddress]);

  const padded = '0x' + checksummedAddress.slice(2).toLowerCase().padStart(64, '0');
  await createVariable(alchemyAuthToken, 'trackedAddressesPadded', [padded]);
  console.log('Address tracked via Alchemy:', checksummedAddress);

  return {
    statusCode: 200,
    body: JSON.stringify({
      safeAddress,
      ownerAddress,
      deploymentStatus: 'NONE',
    }),
  };
}
