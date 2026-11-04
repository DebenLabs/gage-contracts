import { loadConfig } from "./config.js";
import { createContext, runPass } from "./keeper.js";
import { createLogger } from "./log.js";

/** `--once` runs one pass and exits; otherwise a pass every INTERVAL_MS until SIGINT or SIGTERM. */
async function main(): Promise<void> {
  const once = process.argv.includes("--once");
  const { config, keeperKey } = loadConfig();
  const log = createLogger(config.logLevel);
  const ctx = createContext(config, keeperKey, log);
  log.info("start", { ...config, keeper: ctx.account?.address ?? null, once });
  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => (stopping = true));
  do {
    try {
      const reports = await runPass(ctx);
      log.info("pass", { sides: reports });
    } catch (error) {
      log.error("pass_failed", { error });
      if (once) process.exitCode = 1;
    }
    if (once || stopping) break;
    await new Promise((r) => setTimeout(r, config.intervalMs));
  } while (!stopping);
}

void main();
