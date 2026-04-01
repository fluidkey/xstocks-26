import { CORS_HEADERS } from '../_utils/cors-headers';
import { dynamo } from '../_utils/dynamo-client';

export async function handler(event: {
  pathParameters?: Record<string, string | undefined>;
}) {
  const address = event.pathParameters?.address?.toLowerCase();
  if (!address) {
    return {
      statusCode: 400,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      body: JSON.stringify({ error: 'Missing address' }),
    };
  }

  const result = await dynamo.query({
    TableName: 'xstocks-address-transaction',
    KeyConditionExpression: 'address = :address',
    FilterExpression: '#type <> :excludeType',
    ExpressionAttributeNames: { '#type': 'type' },
    ExpressionAttributeValues: { ':address': address, ':excludeType': 'NATIVE_INTERNAL' },
    ScanIndexForward: false,
  });

  const data = (result.Items ?? []).map(item => ({
    txHash: item.txHash,
    blockNumber: item.blockNumber,
    timestamp: item.timestamp,
    from: item.from,
    to: item.to,
    amount: item.amount,
    tokenContract: item.tokenContract,
    type: item.type,
    direction: item.direction,
  }));

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    body: JSON.stringify({ data }),
  };
}
