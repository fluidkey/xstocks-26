import {
  extractViewingPrivateKeyNode,
  generateEphemeralPrivateKey,
  generateKeysFromSignature,
  generateStealthAddresses,
  generateStealthPrivateKey,
  generateFluidkeyMessage,
  predictStealthSafeAddressWithClient,
} from "@fluidkey/stealth-account-kit";
import { privateKeyToAccount } from "viem/accounts";
import { http } from "viem";
import { getEnv } from "@/lib/env";
import type { InitializerExtraFields } from "@fluidkey/stealth-account-kit";

/** Fluidkey ephemeral derivation uses chainId 0 per stealth-account-kit README. */
const EPHEMERAL_CHAIN_ID = 0;

export type GeneratedStealthSafe = {
  stealthSafeAddress: `0x${string}`;
  stealthOwnerAddresses: `0x${string}`[];
  stealthPrivateKey: `0x${string}`;
  nonce: bigint;
};

function buildInitializerExtra(): InitializerExtraFields | undefined {
  const env = getEnv();
  const { to, data, fallbackHandler } = env.safeInitializer;
  if (!to || !data) return undefined;
  return { to, data, fallbackHandler };
}

export async function generateStealthSafeForNonce({
  userPrivateKey,
  userPin,
  userAddress,
  nonce,
  viewingPrivateKeyNodeNumber = 0,
}: {
  userPrivateKey: `0x${string}`;
  userPin: string;
  userAddress: string;
  nonce: bigint;
  viewingPrivateKeyNodeNumber?: number;
}): Promise<GeneratedStealthSafe> {
  const account = privateKeyToAccount(userPrivateKey);
  if (account.address.toLowerCase() !== userAddress.toLowerCase()) {
    throw new Error("Demo account address does not match private key.");
  }

  const { message } = generateFluidkeyMessage({
    pin: userPin,
    address: userAddress,
  });

  const signature = await account.signMessage({ message });

  const { spendingPrivateKey, viewingPrivateKey } =
    generateKeysFromSignature(signature);

  const privateViewingKeyNode = extractViewingPrivateKeyNode(
    viewingPrivateKey,
    viewingPrivateKeyNodeNumber,
  );

  const spendingAccount = privateKeyToAccount(spendingPrivateKey);
  const spendingPublicKey = spendingAccount.publicKey;

  const { ephemeralPrivateKey } = generateEphemeralPrivateKey({
    viewingPrivateKeyNode: privateViewingKeyNode,
    nonce,
    chainId: EPHEMERAL_CHAIN_ID,
  });

  const { stealthAddresses } = generateStealthAddresses({
    spendingPublicKeys: [spendingPublicKey],
    ephemeralPrivateKey,
  });

  const env = getEnv();
  const transport = env.rpcUrl ? http(env.rpcUrl) : undefined;

  const initializerExtraFields = buildInitializerExtra();

  const { stealthSafeAddress } = await predictStealthSafeAddressWithClient({
    threshold: 1,
    stealthAddresses,
    safeVersion: "1.3.0",
    useDefaultAddress: true,
    transport,
    initializerExtraFields,
  });

  const ephemeralAccount = privateKeyToAccount(ephemeralPrivateKey);
  const { stealthPrivateKey } = generateStealthPrivateKey({
    spendingPrivateKey,
    ephemeralPublicKey: ephemeralAccount.publicKey,
  });

  return {
    stealthSafeAddress,
    stealthOwnerAddresses: stealthAddresses,
    stealthPrivateKey,
    nonce,
  };
}
