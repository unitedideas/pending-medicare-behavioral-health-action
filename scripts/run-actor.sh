#!/usr/bin/env bash
set -euo pipefail

actor_id="actablesite~pending-medicare-behavioral-health-actor"
actor_url="https://apify.com/actablesite/pending-medicare-behavioral-health-actor"
public_preview_url="https://raw.githubusercontent.com/unitedideas/pending-medicare-behavioral-health-actor/main/sample/preview.json"
public_receipt_url="https://raw.githubusercontent.com/unitedideas/pending-medicare-behavioral-health-actor/main/sample/receipt.json"
cms_method_url="https://data.cms.gov/resources/fee-for-service-public-provider-enrollment-methodology"
preview="${PREVIEW:-true}"
states="${STATES:-}"
max_charge="${MAX_TOTAL_CHARGE_USD:-0.10}"
output_file="${OUTPUT_FILE:-pending-medicare-behavioral-health.json}"

if [[ "$preview" != "true" && "$preview" != "false" ]]; then
  echo "preview must be true or false." >&2
  exit 2
fi
if ! [[ "$max_charge" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "max-total-charge-usd must be a non-negative number." >&2
  exit 2
fi
if [[ "$preview" == "false" ]] && ! awk -v value="$max_charge" 'BEGIN { exit !(value >= 12.25) }'; then
  echo "A full edition needs max-total-charge-usd of at least 12.25 to cover the fixed \$12 event and bounded platform usage." >&2
  exit 2
fi
if [[ "$preview" == "false" && -z "${APIFY_TOKEN:-}" ]]; then
  echo "APIFY_TOKEN is required for a full edition. Store it as a GitHub Actions secret." >&2
  exit 2
fi
if [[ "$output_file" == *$'\n'* || "$output_file" == *$'\r'* || "$output_file" == *'`'* || -z "$output_file" ]]; then
  echo "output-file must be a non-empty single-line path without backticks." >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
input_file="$tmp_dir/input.json"
response_file="$tmp_dir/response.json"
receipt_file="$tmp_dir/receipt.json"
states_json="$(jq -Rn --arg states "$states" '$states | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_upcase | select(length > 0))')"
if ! jq -e 'all(.[]; test("^[A-Z]{2}$"))' <<<"$states_json" >/dev/null; then
  echo "states must contain only comma-separated two-letter state or territory codes." >&2
  exit 2
fi

request_file() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local status
  status="$({
    curl --silent --show-error --location \
      --output "$destination" \
      --write-out '%{http_code}' \
      "$url"
  } 2>"$tmp_dir/curl-error")" || {
    printf 'The %s request failed before returning an HTTP response.\n' "$label" >&2
    sed -n '1,3p' "$tmp_dir/curl-error" >&2
    exit 1
  }
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    printf 'The %s request returned HTTP %s.\n' "$label" "$status" >&2
    exit 1
  fi
}

if [[ "$preview" == "true" ]]; then
  request_file "$public_preview_url" "$response_file" "public preview"
  request_file "$public_receipt_url" "$receipt_file" "public receipt"
  if ! jq -e '
    type == "array"
    and length == 10
    and all(.[];
      (.npi | type == "string" and test("^[0-9]{10}$"))
      and (.state | type == "string" and test("^[A-Z]{2}$"))
      and (.pending_status | (type == "string") and (ascii_downcase | contains("pending")))
      and (.cms_pending_source_url | type == "string" and startswith("https://data.cms.gov/"))
    )
  ' "$response_file" >/dev/null; then
    echo "The public preview did not match the pending Medicare sample contract." >&2
    exit 1
  fi
  if ! jq -e '
    .schema_version == 1
    and .access == "free_public_repository_sample"
    and .records_returned == 10
    and (.edition_receipt.sources.physician.current.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.edition_receipt.sources.physician.previous.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.edition_receipt.selected_behavioral_health_records_national | type == "number" and . > 0)
    and (.edition_receipt.by_state | type == "object")
    and (.edition_receipt.by_focus | type == "object")
  ' "$receipt_file" >/dev/null; then
    echo "The public receipt did not match the pending Medicare receipt contract." >&2
    exit 1
  fi
  current_snapshot="$(jq -r '.edition_receipt.sources.physician.current.date' "$receipt_file")"
  prior_snapshot="$(jq -r '.edition_receipt.sources.physician.previous.date' "$receipt_file")"
  selected_national="$(jq -r '.edition_receipt.selected_behavioral_health_records_national' "$receipt_file")"
  jq --argjson states "$states_json" \
    'if ($states | length) == 0 then . else [.[] | select(.state as $state | ($states | index($state)) != null)] end' \
    "$response_file" > "$tmp_dir/filtered.json"
  mv "$tmp_dir/filtered.json" "$response_file"
else
  jq -n --argjson states "$states_json" '{ preview: false, states: $states }' > "$input_file"
  endpoint="https://api.apify.com/v2/acts/${actor_id}/run-sync-get-dataset-items"
  query="timeout=300&memory=512&maxTotalChargeUsd=${max_charge}&format=json&clean=true"
  http_status="$({
    curl --silent --show-error --location \
      --output "$response_file" \
      --write-out '%{http_code}' \
      --request POST \
      --header "Authorization: Bearer ${APIFY_TOKEN}" \
      --header 'Content-Type: application/json' \
      --data-binary "@${input_file}" \
      "${endpoint}?${query}"
  } 2>"$tmp_dir/curl-error")" || {
    echo "The Apify request failed before returning an HTTP response." >&2
    sed -n '1,3p' "$tmp_dir/curl-error" >&2
    exit 1
  }
  if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    error_message="$(jq -r '.error.message // .message // "Apify run failed"' "$response_file" 2>/dev/null || printf 'Apify run failed')"
    printf 'Apify returned HTTP %s: %s\n' "$http_status" "$error_message" >&2
    exit 1
  fi
  if ! jq -e 'type == "array"' "$response_file" >/dev/null; then
    echo "Apify returned an invalid dataset response; no output file was published." >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$output_file")"
mv "$response_file" "$output_file"
record_count="$(jq 'length' "$output_file")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'record-count=%s\n' "$record_count" >> "$GITHUB_OUTPUT"
  printf 'output-file=%s\n' "$output_file" >> "$GITHUB_OUTPUT"
  if [[ "$preview" == "true" ]]; then
    printf 'current-snapshot=%s\n' "$current_snapshot" >> "$GITHUB_OUTPUT"
    printf 'prior-snapshot=%s\n' "$prior_snapshot" >> "$GITHUB_OUTPUT"
  fi
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    if [[ "$preview" == "true" ]]; then
      printf '## Pending Medicare behavioral-health preview\n\n'
      printf '**%s current sample records** were written to `%s` without an account, token, payment, or Apify run.\n\n' "$record_count" "$output_file"
      printf -- '- CMS pending-enrollment comparison: **%s versus %s**\n' "$current_snapshot" "$prior_snapshot"
      printf -- '- Validated national edition: **%s behavioral-health records**\n' "$selected_national"
      if [[ "$(jq 'length' <<<"$states_json")" -gt 0 ]]; then
        printf -- '- State filter: **%s**\n' "$(jq -r 'join(", ")' <<<"$states_json")"
      else
        printf -- '- State filter: **all states represented in the public sample**\n'
      fi
      printf -- '- Source method: [CMS fee-for-service public provider enrollment methodology](%s)\n\n' "$cms_method_url"
      printf 'Pending means an application is under contractor review. It does not prove Medicare approval, enrollment, billing privileges, licensure, credentialing, a new practice, availability, interest, or buying intent. Verify every record before consequential use.\n\n'
      printf '[Run the $12 complete current edition on Apify](%s) only when the sample fits. Buyer-paid Apify platform usage is separate.\n' "$actor_url"
    else
      printf '## Pending Medicare behavioral-health export\n\n'
      printf '**%s complete-edition records** were written to `%s` through the caller-funded, cost-capped Apify run.\n\n' "$record_count" "$output_file"
      printf 'Pending does not mean approved, enrolled, credentialed, licensed, available, interested, or ready to buy. Verify every record before consequential use.\n'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
printf 'Wrote %s records to %s.\n' "$record_count" "$output_file"
