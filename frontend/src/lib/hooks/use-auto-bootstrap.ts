"use client";

import { useEffect } from "react";
import {
  createNewDemoAccount,
  getSigningAccount,
  getStoredDemoPrivateKey,
} from "@/lib/demo/local-account";
import { useStealthAccounts } from "@/lib/demo/stealth-accounts-context";
import { registerStealthAccount } from "@/lib/api/client";
import { generateStealthSafeForNonce } from "@/lib/stealth/generate-stealth-safe";
import { getEnv } from "@/lib/env";

let initialStealthInFlight = false;

/**
 * Ensures demo EOA exists and generates the first stealth Safe when the session is empty.
 */
export function useAutoBootstrap() {
  const { accounts, addAccount } = useStealthAccounts();

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!getStoredDemoPrivateKey()) {
      createNewDemoAccount();
    }
  }, []);

  useEffect(() => {
    if (accounts.length > 0) return;

    const pk = getStoredDemoPrivateKey();
    const signer = getSigningAccount();
    if (!pk || !signer) return;
    if (initialStealthInFlight) return;
    initialStealthInFlight = true;

    const env = getEnv();

    void (async () => {
      try {
        const gen = await generateStealthSafeForNonce({
          userPrivateKey: pk,
          userPin: env.demoFluidkeyPin,
          userAddress: signer.address,
          nonce: 0n,
        });

        addAccount({
          label: "Stealth",
          stealthSafeAddress: gen.stealthSafeAddress,
          stealthOwnerAddresses: gen.stealthOwnerAddresses,
          nonce: gen.nonce.toString(),
          stealthPrivateKey: gen.stealthPrivateKey,
        });

        try {
          await registerStealthAccount({
            stealthSafeAddress: gen.stealthSafeAddress,
            stealthOwnerAddresses: gen.stealthOwnerAddresses,
            demoSignerAddress: signer.address,
            nonce: gen.nonce.toString(),
          });
        } catch {
          /* backend optional */
        }
      } catch {
        initialStealthInFlight = false;
      }
    })();
  }, [accounts.length, addAccount]);
}
