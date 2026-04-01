import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';

/** Shared SSM client for reading encrypted parameters */
export const ssm = new SSMClient({});

/**
 * Reads a decrypted SSM parameter by name.
 * Throws if the parameter is missing or has no value.
 * @param name - Full SSM parameter path (e.g. /xstocks/relayer)
 */
export async function getParam(name: string): Promise<string> {
  const result = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  const value = result.Parameter?.Value;
  if (!value) throw new Error(`SSM parameter ${name} not found`);
  return value;
}
