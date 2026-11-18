import { createApp, defaultDeps } from "./app.ts";
import type { Env } from "./env.ts";
import { parsePerRun, runScheduled } from "./fetcher.ts";

const app = createApp();

export default {
  fetch: app.fetch,
  // 30 分ごと（wrangler.toml の [triggers]）: 既読で古い記事を消し、古い順にフィードを取りに行く
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runScheduled(env.DB, defaultDeps, parsePerRun(env.FETCH_PER_RUN)));
  },
} satisfies ExportedHandler<Env>;
