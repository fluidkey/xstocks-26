import { Raleway } from "next/font/google";

/** Raleway 600 for brand wordmark (menu, etc.). Use `.className` where Lato/Work Sans OpenType features must not apply. */
export const ralewaySemibold = Raleway({
  variable: "--font-raleway",
  subsets: ["latin"],
  weight: ["600"],
  display: "swap",
});
