import { createHmac, randomUUID } from 'crypto';
import { SendMessageCommand, SQSClient } from '@aws-sdk/client-sqs';
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { hexToBigInt } from 'viem';
import { AlchemyWebhookEvent } from './types';
import { dynamo } from '../_utils/dynamo-client';

const ssm = new SSMClient({});
const sqs = new SQSClient({});
let cachedSigningKeys: string[] | undefined;

const AUTO_EARN_TOKEN_ADDRESS = '0x00000000efe302beaa2b3e6e1b18d08d69a9012a';

async function getSigningKeys(): Promise<string[]> {
  if (cachedSigningKeys) return cachedSigningKeys;
  const paramName = process.env.ALCHEMY_SIGNING_KEYS_PARAM;
  if (!paramName) throw new Error('ALCHEMY_SIGNING_KEYS_PARAM not set');
  const result = await ssm.send(new GetParameterCommand({ Name: paramName }));
  const value = result.Parameter?.Value;
  if (!value) throw new Error('Signing keys not found in SSM');
  // Comma-separated list of signing keys
  cachedSigningKeys = value.split(',').map(k => k.trim());
  return cachedSigningKeys;
}

function isValidSignature(body: string, signature: string, signingKey: string): boolean {
  const hmac = createHmac('sha256', signingKey);
  hmac.update(body, 'utf8');
  return signature === hmac.digest('hex');
}

export async function handler(event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
    : event.body ?? '';

  console.log('Raw event received:', rawBody);

  // Validate signature against any of the stored signing keys
  if (process.env.SKIP_SIGNATURE_VERIFICATION !== 'true') {
    let signingKeys: string[];
    try {
      signingKeys = await getSigningKeys();
    } catch (err) {
      console.error('Failed to retrieve signing keys:', err);
      return { statusCode: 500, body: 'Server misconfigured' };
    }

    const signature = event.headers['x-alchemy-signature'] ?? event.headers['X-Alchemy-Signature'] ?? '';
    const isValid = signingKeys.some(key => isValidSignature(rawBody, signature, key));
    if (!isValid) {
      console.warn('Invalid signature');
      return { statusCode: 401, body: 'Unauthorized' };
    }
  }

  let webhookEvent: AlchemyWebhookEvent;
  try {
    webhookEvent = JSON.parse(rawBody);
  } catch (err) {
    console.error('Failed to parse body:', err);
    return { statusCode: 400, body: 'Invalid JSON' };
  }

  const block = webhookEvent?.event?.data?.block;
  if (!block) {
    console.warn('No block data in payload');
    return { statusCode: 200, body: 'OK - no block data' };
  }

  const blockTimestamp = typeof block.timestamp === 'number' ? block.timestamp : Math.floor(new Date(block.timestamp).getTime() / 1000);
  const tableName = 'xstocks-address-transaction';

  async function writeTx(params: {
    trackedAddress: string;
    blockNumber: number;
    txHash: string;
    logIndex: string;
    from: string;
    to: string;
    amount: string;
    tokenContract: string;
    type: string;
    direction: string;
  }) {
    await dynamo.put({
      TableName: tableName,
      Item: {
        address: params.trackedAddress.toLowerCase(),
        sk: `${params.blockNumber}#${params.txHash}#${params.logIndex}`,
        txHash: params.txHash,
        blockNumber: params.blockNumber,
        timestamp: blockTimestamp,
        from: params.from.toLowerCase(),
        to: params.to.toLowerCase(),
        amount: params.amount,
        tokenContract: params.tokenContract.toLowerCase(),
        type: params.type,
        direction: params.direction,
      },
    });
  }

  const writes: Promise<void>[] = [];

  // --- Native token transfers (external) ---
  if (block.transactions?.length) {
    for (const tx of block.transactions) {
      const from = tx.from.address.toLowerCase();
      const to = tx.to.address.toLowerCase();
      const amount = hexToBigInt(tx.value as `0x${string}`).toString();
      // Write one record per tracked address side
      writes.push(writeTx({
        trackedAddress: from,
        blockNumber: block.number,
        txHash: tx.hash,
        logIndex: '0',
        from,
        to,
        amount,
        tokenContract: '',
        type: 'NATIVE_EXTERNAL',
        direction: 'OUT',
      }));
      writes.push(writeTx({
        trackedAddress: to,
        blockNumber: block.number,
        txHash: tx.hash,
        logIndex: '0',
        from,
        to,
        amount,
        tokenContract: '',
        type: 'NATIVE_EXTERNAL',
        direction: 'IN',
      }));
    }
  }

  // --- Native token transfers (internal / contract calls) ---
  if (block.callTracerTraces?.length) {
    for (let i = 0; i < block.callTracerTraces.length; i++) {
      const trace = block.callTracerTraces[i];
      const from = trace.from.address.toLowerCase();
      const to = trace.to.address.toLowerCase();
      const amount = hexToBigInt(trace.value as `0x${string}`).toString();
      writes.push(writeTx({
        trackedAddress: from,
        blockNumber: block.number,
        txHash: `trace-${block.hash}`,
        logIndex: String(i),
        from,
        to,
        amount,
        tokenContract: '',
        type: 'NATIVE_INTERNAL',
        direction: 'OUT',
      }));
      writes.push(writeTx({
        trackedAddress: to,
        blockNumber: block.number,
        txHash: `trace-${block.hash}`,
        logIndex: String(i),
        from,
        to,
        amount,
        tokenContract: '',
        type: 'NATIVE_INTERNAL',
        direction: 'IN',
      }));
    }
  }

  // --- ERC-20 transfers ---
  if (block.logs?.length) {
    for (let i = 0; i < block.logs.length; i++) {
      const log = block.logs[i];
      const from = log.transaction.from.address.toLowerCase();
      const to = log.transaction.to.address.toLowerCase();
      const tokenContract = log.account.address.toLowerCase();
      const amount = hexToBigInt(log.data as `0x${string}`).toString();
      // Decode from/to from topics if available (ERC-20 Transfer event)
      const topicFrom = log.topics[1] ? ('0x' + log.topics[1].slice(26)).toLowerCase() : from;
      const topicTo = log.topics[2] ? ('0x' + log.topics[2].slice(26)).toLowerCase() : to;
      writes.push(writeTx({
        trackedAddress: topicFrom,
        blockNumber: block.number,
        txHash: log.transaction.hash,
        logIndex: String(i),
        from: topicFrom,
        to: topicTo,
        amount,
        tokenContract,
        type: 'ERC20_TRANSFER',
        direction: 'OUT',
      }));
      writes.push(writeTx({
        trackedAddress: topicTo,
        blockNumber: block.number,
        txHash: log.transaction.hash,
        logIndex: String(i),
        from: topicFrom,
        to: topicTo,
        amount,
        tokenContract,
        type: 'ERC20_TRANSFER',
        direction: 'IN',
      }));
    }
  }

  await Promise.all(writes);
  console.log(`Wrote ${writes.length} transaction records`);

  // --- Trigger execute-auto-earn for ERC-20 IN transfers of the tracked token ---
  const sqsMessages: Promise<unknown>[] = [];
  if (block.logs?.length) {
    for (const log of block.logs) {
      const tokenContract = log.account.address.toLowerCase();
      if (tokenContract !== AUTO_EARN_TOKEN_ADDRESS) continue;

      const topicTo = log.topics[2] ? ('0x' + log.topics[2].slice(26)).toLowerCase() : null;
      if (!topicTo) continue;

      // Check if topicTo is one of our tracked stealth safes
      const gsiResult = await dynamo.query({
        TableName: 'xstocks-user-address',
        IndexName: 'address-index',
        KeyConditionExpression: 'address = :address',
        ExpressionAttributeValues: { ':address': topicTo },
        Limit: 1,
      });

      if (!gsiResult.Items?.length) continue;

      console.log(`Sending SQS message for safe ${topicTo}, token ${tokenContract}`);
      sqsMessages.push(
        sqs.send(new SendMessageCommand({
          QueueUrl: process.env.TX_RELAY_QUEUE_URL!,
          MessageBody: JSON.stringify({
            safeAddress: topicTo,
            tokenAddress: tokenContract,
          }),
          MessageGroupId: 'relayer',
          MessageDeduplicationId: randomUUID(),
        })),
      );
    }
  }

  if (sqsMessages.length > 0) {
    await Promise.all(sqsMessages);
    console.log(`Sent ${sqsMessages.length} messages to TX relay queue`);
  }

  return { statusCode: 200, body: 'OK' };
}
