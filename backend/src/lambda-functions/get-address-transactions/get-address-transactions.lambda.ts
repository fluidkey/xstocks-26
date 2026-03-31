import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, QueryCommand } from '@aws-sdk/lib-dynamodb';

const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({}));

export async function handler(event: {
  pathParameters?: Record<string, string | undefined>;
}) {
  const address = event.pathParameters?.address?.toLowerCase();
  if (!address) {
    return {
      statusCode: 400,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'Missing address' }),
    };
  }

  const result = await dynamo.send(new QueryCommand({
    TableName: 'xstocks-address-transaction',
    KeyConditionExpression: 'address = :address',
    ExpressionAttributeValues: { ':address': address },
    ScanIndexForward: false,
  }));

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
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ data }),
  };
}
