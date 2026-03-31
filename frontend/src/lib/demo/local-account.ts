import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { isHex } from "viem";

const STORAGE_KEY = "xstocks-demo-eoa-private-key";

const demoKeyListeners = new Set<() => void>();

function emitDemoKeyChange() {
  demoKeyListeners.forEach((l) => l());
}

export function subscribeDemoKey(cb: () => void) {
  demoKeyListeners.add(cb);
  return () => {
    demoKeyListeners.delete(cb);
  };
}

export function persistDemoPrivateKey(privateKey: `0x${string}`): void {
  if (typeof window === "undefined") return;
  localStorage.setItem(STORAGE_KEY, privateKey);
  emitDemoKeyChange();
}

export function clearDemoPrivateKey(): void {
  if (typeof window === "undefined") return;
  localStorage.removeItem(STORAGE_KEY);
  emitDemoKeyChange();
}

export function getStoredDemoPrivateKey(): `0x${string}` | null {
  if (typeof window === "undefined") return null;
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw || !isHex(raw) || raw.length !== 66) return null;
  return raw as `0x${string}`;
}

export function getSigningAccount(): PrivateKeyAccount | null {
  const pk = getStoredDemoPrivateKey();
  return pk ? privateKeyToAccount(pk) : null;
}

export function createNewDemoAccount(): PrivateKeyAccount {
  const pk = generatePrivateKey();
  persistDemoPrivateKey(pk);
  return privateKeyToAccount(pk);
}

export function importDemoPrivateKey(key: `0x${string}`): PrivateKeyAccount {
  const account = privateKeyToAccount(key);
  persistDemoPrivateKey(key);
  return account;
}
