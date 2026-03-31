import { createConfig, http } from "wagmi";
import { mainnet } from "wagmi/chains";
import { getEnv } from "./env";

const env = getEnv();

const transport = env.rpcUrl
  ? http(env.rpcUrl)
  : http("https://eth.llamarpc.com");

export const wagmiConfig = createConfig({
  chains: [mainnet],
  transports: {
    [mainnet.id]: transport,
  },
});
