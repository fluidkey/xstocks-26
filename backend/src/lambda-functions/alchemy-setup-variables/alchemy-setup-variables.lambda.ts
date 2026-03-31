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
  console.log(`Creating variable ${variableName} with ${items.length} items`);

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

  console.log(`Variable ${variableName} created successfully`);
}

export async function handler(event: {
  trackedAddresses: string[];
}) {
  const authToken = await getParam(process.env.ALCHEMY_AUTH_TOKEN_PARAM!);

  const { trackedAddresses } = event;

  if (!trackedAddresses?.length) throw new Error('trackedAddresses is required');

  // Zero-pad addresses to 32 bytes for log topic filtering
  const trackedAddressesPadded = trackedAddresses.map(
    addr => '0x' + addr.slice(2).toLowerCase().padStart(64, '0'),
  );

  await createVariable(authToken, 'trackedAddresses', trackedAddresses);
  await createVariable(authToken, 'trackedAddressesPadded', trackedAddressesPadded);

  return {
    statusCode: 200,
    body: JSON.stringify({
      message: 'Variables created',
      trackedAddresses: trackedAddresses.length,
    }),
  };
}
