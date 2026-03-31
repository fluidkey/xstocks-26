"use client";

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useSyncExternalStore,
} from "react";

const STORAGE_KEY = "xstocks-stealth-accounts-v1";

export type StealthAccountRecord = {
  id: string;
  label: string;
  stealthSafeAddress: `0x${string}`;
  stealthOwnerAddresses: `0x${string}`[];
  nonce: string;
  stealthPrivateKey: `0x${string}`;
  createdAt: number;
};

type SessionState = {
  accounts: StealthAccountRecord[];
  activeDepositSafeId: string | null;
};

const EMPTY_ACCOUNTS: StealthAccountRecord[] = [];

const EMPTY_SESSION: SessionState = {
  accounts: EMPTY_ACCOUNTS,
  activeDepositSafeId: null,
};

const stealthListeners = new Set<() => void>();

function emitStealthAccountsChange() {
  stealthListeners.forEach((l) => l());
}

function subscribeStealthStorage(cb: () => void) {
  stealthListeners.add(cb);
  return () => {
    stealthListeners.delete(cb);
  };
}

function parseSession(raw: string | null): SessionState {
  if (!raw) return EMPTY_SESSION;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (Array.isArray(parsed)) {
      const accounts = parsed as StealthAccountRecord[];
      const safe = accounts.length > 0 ? accounts : EMPTY_ACCOUNTS;
      const active =
        accounts.length > 0 ? accounts[accounts.length - 1].id : null;
      return { accounts: safe, activeDepositSafeId: active };
    }
    if (parsed && typeof parsed === "object" && "accounts" in parsed) {
      const obj = parsed as {
        accounts: StealthAccountRecord[];
        activeDepositSafeId?: string | null;
      };
      const accounts = Array.isArray(obj.accounts) ? obj.accounts : [];
      const safe = accounts.length > 0 ? accounts : EMPTY_ACCOUNTS;
      const active =
        typeof obj.activeDepositSafeId === "string"
          ? obj.activeDepositSafeId
          : safe.length > 0
            ? safe[safe.length - 1].id
            : null;
      return { accounts: safe, activeDepositSafeId: active };
    }
    return EMPTY_SESSION;
  } catch {
    return EMPTY_SESSION;
  }
}

let clientStorageRaw: string | null = null;
let clientSession: SessionState = EMPTY_SESSION;

function getSessionSnapshot(): SessionState {
  if (typeof window === "undefined") return EMPTY_SESSION;
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw === clientStorageRaw) return clientSession;
  clientStorageRaw = raw;
  clientSession = parseSession(raw);
  return clientSession;
}

function saveSession(state: SessionState) {
  if (typeof window === "undefined") return;
  const nextList = state.accounts.length > 0 ? state.accounts : [];
  const json = JSON.stringify({
    accounts: nextList,
    activeDepositSafeId: state.activeDepositSafeId,
  });
  localStorage.setItem(STORAGE_KEY, json);
  clientStorageRaw = json;
  clientSession = {
    accounts: nextList.length > 0 ? nextList : EMPTY_ACCOUNTS,
    activeDepositSafeId: state.activeDepositSafeId,
  };
  emitStealthAccountsChange();
}

type StealthAccountsContextValue = {
  accounts: StealthAccountRecord[];
  activeDepositSafeId: string | null;
  activeAccount: StealthAccountRecord | null;
  addAccount: (
    record: Omit<StealthAccountRecord, "id" | "createdAt">,
    opts?: { setAsActive?: boolean },
  ) => string;
  setActiveDepositSafeId: (id: string | null) => void;
  removeAccount: (id: string) => void;
  updateLabel: (id: string, label: string) => void;
};

const StealthAccountsContext = createContext<
  StealthAccountsContextValue | undefined
>(undefined);

export function StealthAccountsProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const session = useSyncExternalStore(
    subscribeStealthStorage,
    getSessionSnapshot,
    getServerSessionSnapshot,
  );

  const activeAccount = useMemo(() => {
    if (session.accounts.length === 0) return null;
    const byId = session.activeDepositSafeId
      ? session.accounts.find((a) => a.id === session.activeDepositSafeId)
      : null;
    return byId ?? session.accounts[session.accounts.length - 1] ?? null;
  }, [session.accounts, session.activeDepositSafeId]);

  const addAccount = useCallback(
    (
      record: Omit<StealthAccountRecord, "id" | "createdAt">,
      opts?: { setAsActive?: boolean },
    ) => {
      const id = crypto.randomUUID();
      const next: StealthAccountRecord = {
        ...record,
        id,
        createdAt: Date.now(),
      };
      const s = getSessionSnapshot();
      const nextAccounts = [...s.accounts, next];
      let nextActive = s.activeDepositSafeId ?? id;
      if (opts?.setAsActive) nextActive = id;
      saveSession({ accounts: nextAccounts, activeDepositSafeId: nextActive });
      return id;
    },
    [],
  );

  const setActiveDepositSafeId = useCallback((id: string | null) => {
    const s = getSessionSnapshot();
    saveSession({ accounts: s.accounts, activeDepositSafeId: id });
  }, []);

  const removeAccount = useCallback((id: string) => {
    const s = getSessionSnapshot();
    const filtered = s.accounts.filter((a) => a.id !== id);
    let active = s.activeDepositSafeId;
    if (active === id) {
      active = filtered.length > 0 ? filtered[filtered.length - 1].id : null;
    }
    saveSession({ accounts: filtered, activeDepositSafeId: active });
  }, []);

  const updateLabel = useCallback((id: string, label: string) => {
    const s = getSessionSnapshot();
    saveSession({
      accounts: s.accounts.map((a) => (a.id === id ? { ...a, label } : a)),
      activeDepositSafeId: s.activeDepositSafeId,
    });
  }, []);

  const value = useMemo(
    () => ({
      accounts: session.accounts,
      activeDepositSafeId: session.activeDepositSafeId,
      activeAccount,
      addAccount,
      setActiveDepositSafeId,
      removeAccount,
      updateLabel,
    }),
    [
      session.accounts,
      session.activeDepositSafeId,
      activeAccount,
      addAccount,
      setActiveDepositSafeId,
      removeAccount,
      updateLabel,
    ],
  );

  return (
    <StealthAccountsContext.Provider value={value}>
      {children}
    </StealthAccountsContext.Provider>
  );
}

function getServerSessionSnapshot(): SessionState {
  return EMPTY_SESSION;
}

export function useStealthAccounts() {
  const ctx = useContext(StealthAccountsContext);
  if (!ctx) {
    throw new Error(
      "useStealthAccounts must be used within StealthAccountsProvider",
    );
  }
  return ctx;
}
