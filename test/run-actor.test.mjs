import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";

const root = new URL("../", import.meta.url).pathname;
const script = path.join(root, "scripts/run-actor.sh");

const previewRecords = [
  { npi: "1234567890", state: "CA", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567891", state: "TX", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567892", state: "FL", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567893", state: "NY", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567894", state: "WA", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567895", state: "CA", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567896", state: "CO", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567897", state: "CT", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567898", state: "AL", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
  { npi: "1234567899", state: "NC", pending_status: "Pending first-time Medicare enrollment application", cms_pending_source_url: "https://data.cms.gov/example" },
];

const previewReceipt = {
  schema_version: 1,
  access: "free_public_repository_sample",
  records_returned: 10,
  edition_receipt: {
    sources: { physician: { current: { date: "2026-07-13" }, previous: { date: "2026-07-09" } } },
    selected_behavioral_health_records_national: 211,
    by_state: { CA: 31, TX: 23 },
    by_focus: { "Mental health counselor": 84, "Professional counselor": 72, "Marriage and family therapist": 45, Psychologist: 10 },
  },
};

async function fixture() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "pending-medicare-action-"));
  const bin = path.join(directory, "bin");
  await mkdir(bin);
  const curl = path.join(bin, "curl");
  await writeFile(curl, `#!/usr/bin/env bash
set -euo pipefail
output=""
input=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --data-binary) input="\${2#@}"; shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ -n "$input" && -n "\${CAPTURE_INPUT:-}" ]]; then
  cp "$input" "$CAPTURE_INPUT"
fi
if [[ "$url" == *"receipt.json" ]]; then
  printf '%s' "$FAKE_RECEIPT_BODY" > "$output"
  printf '%s' "$FAKE_RECEIPT_STATUS"
else
  printf '%s' "$FAKE_CURL_BODY" > "$output"
  printf '%s' "$FAKE_CURL_STATUS"
fi
`, { mode: 0o755 });
  return { directory, bin };
}

function run(env) {
  return new Promise((resolve) => {
    const child = spawn("bash", [script], { env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function previewEnv(bin) {
  return {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    PREVIEW: "true",
    MAX_TOTAL_CHARGE_USD: "0.10",
    FAKE_CURL_BODY: JSON.stringify(previewRecords),
    FAKE_CURL_STATUS: "200",
    FAKE_RECEIPT_BODY: JSON.stringify(previewReceipt),
    FAKE_RECEIPT_STATUS: "200",
  };
}

test("free preview needs no token, filters states, and publishes source-linked outputs", async () => {
  const { directory, bin } = await fixture();
  const output = path.join(directory, "result.json");
  const githubOutput = path.join(directory, "github-output.txt");
  const githubSummary = path.join(directory, "github-summary.md");
  const result = await run({
    ...previewEnv(bin),
    STATES: " ca, TX ",
    OUTPUT_FILE: output,
    GITHUB_OUTPUT: githubOutput,
    GITHUB_STEP_SUMMARY: githubSummary,
  });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(await readFile(output, "utf8")).length, 3);
  const outputs = await readFile(githubOutput, "utf8");
  assert.match(outputs, /record-count=3/);
  assert.match(outputs, /current-snapshot=2026-07-13/);
  assert.match(outputs, /prior-snapshot=2026-07-09/);
  const summary = await readFile(githubSummary, "utf8");
  assert.match(summary, /without an account, token, payment, or Apify run/);
  assert.match(summary, /2026-07-13 versus 2026-07-09/);
  assert.match(summary, /211 behavioral-health records/);
  assert.match(summary, /State filter: \*\*CA, TX\*\*/);
  assert.match(summary, /Pending means an application is under contractor review/);
  assert.match(summary, /\$12 complete current edition on Apify/);
});

test("state filters reject non-code input before any request", async () => {
  const { bin } = await fixture();
  const result = await run({ ...previewEnv(bin), STATES: "CA,[link](https://example.com)" });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /two-letter state or territory codes/);
});

test("preview receipt failures do not publish a dataset", async () => {
  const { directory, bin } = await fixture();
  const output = path.join(directory, "result.json");
  const result = await run({
    ...previewEnv(bin),
    OUTPUT_FILE: output,
    FAKE_RECEIPT_BODY: JSON.stringify({ schema_version: 0 }),
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /receipt contract/);
});

test("full editions require an Apify token", async () => {
  const { bin } = await fixture();
  const result = await run({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    APIFY_TOKEN: "",
    PREVIEW: "false",
    MAX_TOTAL_CHARGE_USD: "12.25",
  });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /required for a full edition/);
});

test("full runs fail closed below the disclosed charge cap", async () => {
  const { bin } = await fixture();
  const result = await run({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    APIFY_TOKEN: "test-fixture-token",
    PREVIEW: "false",
    MAX_TOTAL_CHARGE_USD: "12.24",
  });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /at least 12\.25/);
});

test("full editions publish fulfillment without another purchase prompt", async () => {
  const { directory, bin } = await fixture();
  const output = path.join(directory, "result.json");
  const capture = path.join(directory, "input.json");
  const githubSummary = path.join(directory, "github-summary.md");
  const result = await run({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    APIFY_TOKEN: "test-fixture-token",
    PREVIEW: "false",
    STATES: "CA",
    MAX_TOTAL_CHARGE_USD: "12.25",
    OUTPUT_FILE: output,
    CAPTURE_INPUT: capture,
    FAKE_CURL_BODY: JSON.stringify([{ npi: "1234567890", state: "CA" }]),
    FAKE_CURL_STATUS: "200",
    GITHUB_STEP_SUMMARY: githubSummary,
  });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(await readFile(capture, "utf8")), { preview: false, states: ["CA"] });
  const summary = await readFile(githubSummary, "utf8");
  assert.match(summary, /\*\*1 complete-edition records\*\*/);
  assert.match(summary, /caller-funded, cost-capped Apify run/);
  assert.doesNotMatch(summary, /Run the \$12 complete current edition/);
});

test("HTTP failures do not publish a dataset", async () => {
  const { directory, bin } = await fixture();
  const output = path.join(directory, "result.json");
  const result = await run({
    ...previewEnv(bin),
    OUTPUT_FILE: output,
    FAKE_CURL_BODY: JSON.stringify({ error: { message: "fixture failure" } }),
    FAKE_CURL_STATUS: "503",
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /public preview request returned HTTP 503/);
});
