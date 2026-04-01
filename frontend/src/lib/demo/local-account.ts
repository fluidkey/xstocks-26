import {
  generatePrivateKey,
  privateKeyToAccount,
  type PrivateKeyAccount,
} from "viem/accounts";
import { isHex } from "viem";

/** Legacy single-key storage (migrated to earn on read). */
const LEGACY_STORAGE_KEY = "xstocks-demo-eoa-private-key";
const STORAGE_KEY_EARN = "xstocks-demo-eoa-earn-private-key";
const STORAGE_KEY_OWN = "xstocks-demo-eoa-own-private-key";

const earnDemoKeyListeners = new Set<() => void>();
const ownDemoKeyListeners = new Set<() => void>();

function migrateLegacyDemoKeyIfNeeded(): void {
  if (typeof window === "undefined") return;
  const legacy = window.localStorage.getItem(LEGACY_STORAGE_KEY);
  if (!legacy || !isHex(legacy) || legacy.length !== 66) {
    return;
  }
  if (!window.localStorage.getItem(STORAGE_KEY_EARN)) {
    window.localStorage.setItem(STORAGE_KEY_EARN, legacy);
  }
  window.localStorage.removeItem(LEGACY_STORAGE_KEY);
}

function emitEarnDemoKeyChange() {
  earnDemoKeyListeners.forEach((l) => l());
}

function emitOwnDemoKeyChange() {
  ownDemoKeyListeners.forEach((l) => l());
}

export function subscribeEarnDemoKey(cb: () => void) {
  earnDemoKeyListeners.add(cb);
  return () => {
    earnDemoKeyListeners.delete(cb);
  };
}

export function subscribeOwnDemoKey(cb: () => void) {
  ownDemoKeyListeners.add(cb);
  return () => {
    ownDemoKeyListeners.delete(cb);
  };
}

export function persistEarnPrivateKey(privateKey: `0x${string}`): void {
  if (typeof window === "undefined") return;
  migrateLegacyDemoKeyIfNeeded();
  window.localStorage.setItem(STORAGE_KEY_EARN, privateKey);
  emitEarnDemoKeyChange();
}

export function persistOwnPrivateKey(privateKey: `0x${string}`): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY_OWN, privateKey);
  emitOwnDemoKeyChange();
}

export function clearEarnPrivateKey(): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(STORAGE_KEY_EARN);
  emitEarnDemoKeyChange();
}

export function clearOwnPrivateKey(): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(STORAGE_KEY_OWN);
  emitOwnDemoKeyChange();
}

export function getStoredEarnPrivateKey(): `0x${string}` | null {
  if (typeof window === "undefined") return null;
  migrateLegacyDemoKeyIfNeeded();
  const raw = window.localStorage.getItem(STORAGE_KEY_EARN);
  if (!raw || !isHex(raw) || raw.length !== 66) return null;
  return raw as `0x${string}`;
}

export function getStoredOwnPrivateKey(): `0x${string}` | null {
  if (typeof window === "undefined") return null;
  const raw = window.localStorage.getItem(STORAGE_KEY_OWN);
  if (!raw || !isHex(raw) || raw.length !== 66) return null;
  return raw as `0x${string}`;
}

export function getEarnSigningAccount(): PrivateKeyAccount | null {
  const pk = getStoredEarnPrivateKey();
  return pk ? privateKeyToAccount(pk) : null;
}

export function getOwnSigningAccount(): PrivateKeyAccount | null {
  const pk = getStoredOwnPrivateKey();
  return pk ? privateKeyToAccount(pk) : null;
}

export function createNewEarnAccount(): PrivateKeyAccount {
  const pk = generatePrivateKey();
  persistEarnPrivateKey(pk);
  return privateKeyToAccount(pk);
}

export function createNewOwnAccount(): PrivateKeyAccount {
  const pk = generatePrivateKey();
  persistOwnPrivateKey(pk);
  return privateKeyToAccount(pk);
}

export function importEarnPrivateKey(key: `0x${string}`): PrivateKeyAccount {
  privateKeyToAccount(key);
  persistEarnPrivateKey(key);
  return privateKeyToAccount(key);
}

export function importOwnPrivateKey(key: `0x${string}`): PrivateKeyAccount {
  privateKeyToAccount(key);
  persistOwnPrivateKey(key);
  return privateKeyToAccount(key);
}
