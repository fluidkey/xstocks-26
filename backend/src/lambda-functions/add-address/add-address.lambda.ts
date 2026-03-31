import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

const ssm = new SSMClient({});

const ALCHEMY_API_URL = 'https://dashboard.alchemy.com/api/graphql/variables';

async function getParam(name: string): Promise<string> {
  const result = await ssm.send(new GetParameterCommand({ Name: name }));
  const value = result.Parameter?.Value;
  if (!value) throw new Error(`SSM parameter ${name} not found`);
  return value;
}

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

interface AddAddressRequest {
  idUser: string;
  address: string;
}

export async function handler(event: {
  body?: string;
  isBase64Encoded?: boolean;
}) {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
    : event.body ?? '';

  let request: AddAddressRequest;
  try {
    request = JSON.parse(rawBody);
  } catch {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  if (!request.address?.startsWith('0x')) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid address' }) };
  }

  const authToken = await getParam(process.env.ALCHEMY_AUTH_TOKEN_PARAM!);

  // Add normal address for transaction/trace filters
  await createVariable(authToken, 'trackedAddresses', [request.address]);

  // Add zero-padded address for log topic filters
  const padded = '0x' + request.address.slice(2).toLowerCase().padStart(64, '0');
  await createVariable(authToken, 'trackedAddressesPadded', [padded]);

  return {
    statusCode: 200,
    body: JSON.stringify({
      message: 'Address added',
      address: request.address,
    }),
  };
}
