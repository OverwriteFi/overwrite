// One entry per chain the app can be pointed at. The JSON files are the deploy's own output
// (contracts/deployments/<chainId>.json), imported statically so they ship in the bundle.
import d46630 from "../../../../contracts/deployments/46630.json";

export const deploymentsByChain: Record<number, unknown> = {
  46630: d46630,
};
