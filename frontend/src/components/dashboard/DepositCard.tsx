"use client";

import { useState } from "react";
import { Check, Copy, Wallet } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

type Props = {
  address: string | null;
  depositConfirmed: boolean;
};

export function DepositCard({ address, depositConfirmed }: Props) {
  const [copied, setCopied] = useState(false);

  const copy = () => {
    if (!address) return;
    void navigator.clipboard.writeText(address).then(() => {
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    });
  };

  return (
    <Card
      className={cn(
        "transition-all duration-300 ease-out",
        depositConfirmed
          ? "border-emerald-500/35 bg-emerald-50/60 shadow-sm ring-1 ring-emerald-500/20"
          : "hover:border-primary/20",
      )}
    >
      <CardHeader className="flex-row items-start justify-between space-y-0">
        <div className="flex items-center gap-2">
          <span
            className={cn(
              "flex size-9 items-center justify-center rounded-lg transition-colors",
              depositConfirmed
                ? "bg-emerald-500/15 text-emerald-700"
                : "bg-muted text-muted-foreground",
            )}
          >
            <Wallet className="size-4" strokeWidth={1.75} />
          </span>
          <div>
            <CardTitle className="text-base font-semibold">Deposit</CardTitle>
            <CardDescription>AUSD to your stealth Safe</CardDescription>
          </div>
        </div>
        {depositConfirmed ? (
          <Badge
            variant="secondary"
            className="border border-emerald-500/25 bg-emerald-100/80 text-emerald-800"
          >
            <Check className="size-3" />
            Received
          </Badge>
        ) : null}
      </CardHeader>
      <CardContent className="space-y-4">
        {address ? (
          <>
            <p className="text-sm leading-relaxed text-foreground">
              Deposit AUSD at{" "}
              <span className="font-mono text-[0.8125rem] font-medium tracking-tight text-primary">
                {address}
              </span>{" "}
              to earn.
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="h-8 gap-1.5"
                onClick={copy}
              >
                {copied ? (
                  <Check className="size-3.5 text-emerald-600" />
                ) : (
                  <Copy className="size-3.5" />
                )}
                {copied ? "Copied" : "Copy address"}
              </Button>
            </div>
          </>
        ) : (
          <div className="space-y-2">
            <Skeleton className="h-4 w-full max-w-md rounded-md" />
            <Skeleton className="h-4 w-3/4 max-w-sm rounded-md" />
          </div>
        )}
        <p className="text-sm text-muted-foreground">
          This address is a stealth address you have full control of.
        </p>
      </CardContent>
    </Card>
  );
}
