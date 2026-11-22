// Sets a TestFlight build's autoNotifyEnabled (the TestFlight app's "a new build is available" push) through
// apple-distribution-kit's signed App Store Connect client, which has no PATCH command of its own.
//   node scripts/asc-build-auto-notify.mjs <kit dist/cli.js> <kit config.json> <buildBetaDetail id> <true|false>
// Prints one JSON line: {"detailId","status","autoNotifyEnabled"} on success, or {"detailId","status","code","message"}
// and exit 1 on failure. Nothing from the key config is printed.
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [kitBin, configPath, detailId, value] = process.argv.slice(2);
if (!kitBin || !configPath || !detailId || !["true", "false"].includes(value ?? "")) {
  console.error("usage: asc-build-auto-notify.mjs <kit dist/cli.js> <config.json> <buildBetaDetail id> <true|false>");
  process.exit(64);
}
const kit = await import(pathToFileURL(join(dirname(kitBin), "index.js")).href);
let status = 0;
const client = kit.createAppStoreConnectClient({
  auth: await kit.loadAscAuth(configPath),
  // The kit's client returns only the body; keep the HTTP status for the record.
  fetch: async (...args) => {
    const response = await fetch(...args);
    status = response.status;
    return response;
  }
});
try {
  const body = await client.request({
    method: "PATCH",
    path: `/v1/buildBetaDetails/${encodeURIComponent(detailId)}`,
    body: { data: { type: "buildBetaDetails", id: detailId, attributes: { autoNotifyEnabled: value === "true" } } }
  });
  console.log(JSON.stringify({ detailId, status, autoNotifyEnabled: body?.data?.attributes?.autoNotifyEnabled ?? null }));
} catch (error) {
  console.log(JSON.stringify({ detailId, status: error?.status ?? status, code: error?.code ?? "request_failed", message: error?.message ?? String(error) }));
  process.exit(1);
}
