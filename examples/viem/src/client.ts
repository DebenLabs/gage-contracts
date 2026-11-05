// A public client on Robinhood Chain mainnet, and gage's addresses from this repository's deployment manifest.
import {createPublicClient, getAddress, http, type Address} from "viem";
import {robinhood} from "viem/chains";
import manifest from "../../../deployments/manifest/4663.json" with {type: "json"};

export const client = createPublicClient({chain: robinhood, transport: http()});

export {manifest};

/** The address at a manifest key, such as `intentV1.core` or `intentV1Assets.NVDA.factory`. */
export function addressOf(key: string): Address {
  const value = key.split(".").reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], manifest);
  if (typeof value !== "string") throw new Error(`no address at ${key} in deployments/manifest/4663.json`);
  return getAddress(value);
}
