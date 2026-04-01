import { CORS_HEADERS } from '../_utils/cors-headers';
import { dynamo } from '../_utils/dynamo-client';

export async function handler(event: {
  pathParameters?: Record<string, string | undefined>;
}) {
  const idUser = event.pathParameters?.id_user;
  if (!idUser) {
    return {
      statusCode: 400,
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      body: JSON.stringify({ error: 'Missing id_user' }),
    };
  }

  const result = await dynamo.query({
    TableName: 'xstocks-user-address',
    KeyConditionExpression: 'idUser = :idUser',
    ExpressionAttributeValues: { ':idUser': idUser },
  });

  const data = (result.Items ?? []).map(item => ({
    address: item.address,
    addedAt: item.addedAt,
  }));

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    body: JSON.stringify({ data }),
  };
}
