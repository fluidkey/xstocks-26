"use client";

import { useEffect } from "react";
import {
  createNewEarnAccount,
  createNewOwnAccount,
  getStoredEarnPrivateKey,
  getStoredOwnPrivateKey,
} from "@/lib/demo/local-account";

const OLD_OWN_SESSIONS_KEY = "xstocks-own-sessions-v1";

/**
 * Ensures demo EOAs exist (Earn and Own private keys in localStorage).
 * Safes are created via POST /address in each flow hook.
 */
export function useAutoBootstrap() {
  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!getStoredEarnPrivateKey()) {
      createNewEarnAccount();
    }
    if (!getStoredOwnPrivateKey()) {
      createNewOwnAccount();
    }
    try {
      window.localStorage.removeItem(OLD_OWN_SESSIONS_KEY);
    } catch {
      /* ignore */
    }
  }, []);
}
