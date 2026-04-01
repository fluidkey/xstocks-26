"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/utils";

export const SEPA_IBAN_OWN = "LU974080000028823872";
export const SEPA_IBAN_EARN = "LU354080000028800156";
export const SEPA_BENEFICIARY_NAME = "Bridge Building Sp. Z.o.o.";

function CopyableText({
  label,
  value,
  className,
  mono,
}: {
  label: string;
  value: string;
  className?: string;
  mono?: boolean;
}) {
  const [copied, setCopied] = useState(false);

  const onClick = () => {
    void navigator.clipboard.writeText(value).then(() => {
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
        mono && "font-mono text-[0.9375rem] font-semibold tracking-tight",
        !mono && "font-semibold",
        className,
      )}
      aria-label={`Copy ${label}`}
    >
      <span
        className={cn(
          "min-w-0 break-all text-primary",
          mono && "tabular-nums",
        )}
      >
        {value}
      </span>
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

/** First timeline row: SEPA deposit instructions with copyable IBAN and beneficiary. */
export function SepaDepositFirstTimelineRow({ iban }: { iban: string }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0 text-base leading-relaxed text-foreground">
        Deposit Euros to{" "}
        <CopyableText label="IBAN" value={iban} mono /> (
        <CopyableText label="beneficiary name" value={SEPA_BENEFICIARY_NAME} />
        )
      </div>
      <span
        className="size-9 shrink-0 opacity-0 pointer-events-none"
        aria-hidden
      />
    </div>
  );
}
