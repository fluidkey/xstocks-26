import { getEnv } from "@/lib/env";

export type RegisterStealthPayload = {
  stealthSafeAddress: `0x${string}`;
  stealthOwnerAddresses: `0x${string}`[];
  demoSignerAddress: `0x${string}`;
  nonce: string;
};

/**
 * Registers a predicted stealth Safe with the backend for auto-earn indexing.
 * Adjust path when the backend contract is finalized.
 */
export async function registerStealthAccount(
  payload: RegisterStealthPayload,
): Promise<Response> {
  const { backendUrl } = getEnv();
  if (!backendUrl) {
    throw new Error(
      "NEXT_PUBLIC_BACKEND_URL is not set; cannot register stealth account.",
    );
  }
  const url = `${backendUrl.replace(/\/$/, "")}/api/stealth-accounts`;
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}
