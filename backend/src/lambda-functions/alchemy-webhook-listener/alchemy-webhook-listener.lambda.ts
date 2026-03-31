import { createHmac } from 'crypto';
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

const ssm = new SSMClient({});
let cachedSigningKeys: string[] | undefined;

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

interface AlchemyWebhookEvent {
  webhookId: string;
  id: string;
  createdAt: string;
  type: string;
  event: {
    data: {
      block: {
        hash: string;
        number: number;
        timestamp: string;
        transactions?: Transaction[];
        callTracerTraces?: Trace[];
        logs?: Log[];
      };
    };
    sequenceNumber: string;
  };
}

interface Transaction {
  hash: string;
  from: { address: string };
  to: { address: string };
  value: string;
  gas: number;
  status: number;
}

interface Trace {
  from: { address: string };
  to: { address: string };
  value: string;
  type: string;
}

interface Log {
  topics: string[];
  data: string;
  account: { address: string };
  transaction: {
    hash: string;
    from: { address: string };
    to: { address: string };
    value: string;
    status: number;
  };
}

export async function handler(event: {
  headers: Record<string, string | undefined>;
  body?: string;
  isBase64Encoded?: boolean;
}) {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
    : event.body ?? '';

  console.log('Raw event received:', rawBody);

  // Validate signature against any of the stored signing keys
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

  // --- Native token transfers (external) ---
  if (block.transactions?.length) {
    for (const tx of block.transactions) {
      console.log(JSON.stringify({
        type: 'NATIVE_EXTERNAL',
        hash: tx.hash,
        from: tx.from.address,
        to: tx.to.address,
        value: tx.value,
        status: tx.status,
      }));
    }
  }

  // --- Native token transfers (internal / contract calls) ---
  if (block.callTracerTraces?.length) {
    for (const trace of block.callTracerTraces) {
      console.log(JSON.stringify({
        type: 'NATIVE_INTERNAL',
        from: trace.from.address,
        to: trace.to.address,
        value: trace.value,
        traceType: trace.type,
      }));
    }
  }

  // --- ERC-20 transfers ---
  if (block.logs?.length) {
    for (const log of block.logs) {
      console.log(JSON.stringify({
        type: 'ERC20_TRANSFER',
        tokenContract: log.account.address,
        txHash: log.transaction.hash,
        from: log.transaction.from.address,
        to: log.transaction.to.address,
        topics: log.topics,
        data: log.data,
      }));
    }
  }

  return { statusCode: 200, body: 'OK' };
}
