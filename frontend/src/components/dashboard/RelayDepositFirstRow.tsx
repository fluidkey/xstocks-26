"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/utils";

function CopyableAddress({
  address,
  copyAriaLabel,
}: {
  address: string;
  copyAriaLabel: string;
}) {
  const [copied, setCopied] = useState(false);
  const onClick = () => {
    void navigator.clipboard.writeText(address).then(() => {
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    });
  };
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "group inline-flex max-w-full items-center gap-1 rounded-md px-1 py-0.5 text-left transition-colors",
        "hover:bg-primary/8 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        "font-mono text-[0.9375rem] font-semibold tracking-tight tabular-nums",
      )}
      aria-label={copyAriaLabel}
    >
      <span className="min-w-0 break-all text-primary">{address}</span>
      {copied ? (
        <Check
          className="size-3.5 shrink-0 text-emerald-600"
          strokeWidth={2.5}
          aria-hidden
        />
      ) : (
        <Copy
          className="size-3.5 shrink-0 text-muted-foreground opacity-60 transition-opacity group-hover:opacity-100"
          strokeWidth={2}
          aria-hidden
        />
      )}
    </button>
  );
}

type Props = {
  relayAddress: string;
  chainLabel: string;
  /** Shown after “Deposit via … on … to …”. */
  assetLabel?: string;
  copyAriaLabel?: string;
};

export function RelayDepositFirstRow({
  relayAddress,
  chainLabel,
  assetLabel = "USDC",
  copyAriaLabel = "Copy deposit address",
}: Props) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0 text-sm leading-snug text-foreground">
        or deposit via {assetLabel} on{" "}
        {chainLabel} to{" "}
        <CopyableAddress address={relayAddress} copyAriaLabel={copyAriaLabel} />
      </div>
      <span
        className="size-9 shrink-0 opacity-0 pointer-events-none"
        aria-hidden
      />
    </div>
  );
}
