import { getAddress, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { dynamo } from '../_utils/dynamo-client';
import { getInitializerExtraFields } from '../_utils/initializer-extra-fields';
import { initPredictedSafe } from '../_utils/safe-init';
import { getParam } from '../_utils/ssm-params';
import { CreateStealthSafeRequest } from './types';

const ALCHEMY_API_URL = 'https://dashboard.alchemy.com/api/graphql/variables';

const VALID_ID_USERS = ['own', 'earn'] as const;
type ValidIdUser = typeof VALID_ID_USERS[number];

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

  if (!VALID_ID_USERS.includes(request.idUser as ValidIdUser)) {
    return { statusCode: 400, body: JSON.stringify({ error: `idUser must be one of: ${VALID_ID_USERS.join(', ')}` }) };
  }

  const { idUser, ownerAddress } = request;

  // 1. Read secrets from SSM
  const [relayerPrivateKey, alchemyApiKey, alchemyAuthToken, bridgeCustomerId, bridgeApiKey, bridgeVirtualAccountOwn, bridgeVirtualAccountEarn] = await Promise.all([
    getParam('/xstocks/relayer'),
    getParam('/xstocks/alchemy-api-key'),
    getParam('/xstocks/alchemy-auth-token'),
    getParam('/xstocks/bridgexyz-customer-id'),
    getParam('/xstocks/bridgexyz-api-key'),
    getParam('/xstocks/bridgexyz-virtual-account-own'),
    getParam('/xstocks/bridgexyz-virtual-account-earn'),
  ]);

  const bridgeVirtualAccount = idUser === 'own' ? bridgeVirtualAccountOwn : bridgeVirtualAccountEarn;
  const relayerAccount = privateKeyToAccount(relayerPrivateKey as `0x${string}`);
  const providerUrl = `https://eth-mainnet.g.alchemy.com/v2/${alchemyApiKey}`;

  // 2. Get initializer extra fields (enables AutoEarn module during deployment)
  const initializerExtra = getInitializerExtraFields();

  // 3. Predict the safe address (no on-chain tx yet)
  const protocolKit = await initPredictedSafe({
    providerUrl,
    signerPrivateKey: relayerPrivateKey,
    ownerAddress: relayerAccount.address,
    initializerExtraTo: initializerExtra.to,
    initializerExtraData: initializerExtra.data,
    saltNonce: toHex(0),
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

  // 6. Get Relay deposit address for USDC -> AUSD swap to the safe
  const relayRes = await fetch('https://api.relay.link/quote/v2', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      user: '0x0000000000000000000000000000000000000000',
      originChainId: 1,
      originCurrency: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // USDC
      destinationChainId: 1,
      destinationCurrency: '0x00000000efe302beaa2b3e6e1b18d08d69a9012a', // AUSD
      tradeType: 'EXACT_INPUT',
      recipient: checksummedAddress,
      amount: '2000000', // minimum amount to get a quote
      useDepositAddress: true,
      usePermit: false,
      useExternalLiquidity: false,
      refundTo: checksummedAddress,
    }),
  });

  if (!relayRes.ok) {
    const relayBody = await relayRes.text();
    console.error(`Relay API failed: ${relayRes.status} ${relayBody}`);
    throw new Error(`Relay API failed: ${relayRes.status}`);
  }

  const relayData = await relayRes.json() as { steps: Array<{ depositAddress?: string }> };
  const depositAddress = relayData.steps?.[0]?.depositAddress;
  if (!depositAddress) {
    throw new Error('No depositAddress returned from Relay API');
  }
  console.log('Relay deposit address:', depositAddress);

  // 7. Update Bridge virtual account with the Relay deposit address
  const bridgeRes = await fetch(
    `https://api.bridge.xyz/v0/customers/${bridgeCustomerId}/virtual_accounts/${bridgeVirtualAccount}`,
    {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        'Api-Key': bridgeApiKey,
      },
      body: JSON.stringify({
        destination: {
          currency: 'usdc',
          payment_rail: 'ethereum',
          address: depositAddress,
        },
      }),
    },
  );

  if (!bridgeRes.ok) {
    const bridgeBody = await bridgeRes.text();
    console.error(`Bridge API failed: ${bridgeRes.status} ${bridgeBody}`);
    throw new Error(`Bridge API failed: ${bridgeRes.status}`);
  }
  console.log('Bridge virtual account updated with deposit address:', depositAddress);

  // 8. Store deposit address in DynamoDB
  await dynamo.update({
    TableName: 'xstocks-user-address',
    Key: { idUser, address: safeAddress.toLowerCase() },
    UpdateExpression: 'SET relayDepositAddress = :depositAddress',
    ExpressionAttributeValues: { ':depositAddress': depositAddress },
  });

  return {
    statusCode: 200,
    body: JSON.stringify({
      safeAddress,
      ownerAddress,
      deploymentStatus: 'NONE',
    }),
  };
}
