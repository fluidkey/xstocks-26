"use client";

import { Landmark, Loader2 } from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { cn } from "@/lib/utils";

type Props = {
  inProgress: boolean;
  done: boolean;
};

export function RoutingCard({ inProgress, done }: Props) {
  const stateLabel = done
    ? "Complete"
    : inProgress
      ? "Routing"
      : "Waiting";

  return (
    <Card
      className={cn(
        "transition-all duration-300 ease-out",
        done
          ? "border-emerald-500/35 bg-emerald-50/60 shadow-sm ring-1 ring-emerald-500/20"
          : inProgress
            ? "border-primary/20 shadow-sm ring-1 ring-primary/10"
            : "opacity-95",
      )}
    >
      <CardHeader className="flex-row items-start justify-between space-y-0">
        <div className="flex items-center gap-2">
          <span
            className={cn(
              "flex size-9 items-center justify-center rounded-lg transition-colors",
              done
                ? "bg-emerald-500/15 text-emerald-700"
                : inProgress
                  ? "bg-primary/10 text-primary"
                  : "bg-muted text-muted-foreground",
            )}
          >
            {inProgress && !done ? (
              <Loader2
                className="size-4 animate-spin"
                strokeWidth={1.75}
                aria-hidden
              />
            ) : (
              <Landmark className="size-4" strokeWidth={1.75} />
            )}
          </span>
          <div>
            <CardTitle className="text-base font-semibold">
              Auto-routing to Morpho vault
            </CardTitle>
            <CardDescription>Yield vault allocation</CardDescription>
          </div>
        </div>
        <Badge
          variant="outline"
          className={cn(
            "font-normal tabular-nums",
            inProgress &&
              !done &&
              "border-primary/25 bg-primary/5 text-primary animate-pulse",
            done && "border-emerald-500/30 bg-emerald-50 text-emerald-800",
          )}
        >
          {stateLabel}
        </Badge>
      </CardHeader>
      <CardContent className="space-y-3">
        <Separator className="bg-border/80" />
        <p className="text-sm text-muted-foreground">
          {done
            ? "Funds are earning in the vault. Your next deposit address is ready below."
            : inProgress
              ? "Moving your deposit into the strategy vault…"
              : "Starts once we see AUSD on your stealth Safe."}
        </p>
      </CardContent>
    </Card>
  );
}
