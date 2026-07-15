# Pending Medicare behavioral-health data in GitHub Actions

Download behavioral-health NPIs newly present in the latest CMS pending first-time Medicare enrollment files. The free preview needs no account, token, email, payment, or Apify run and writes 10 current public records as clean JSON inside your workflow.

When the sample fits, the complete edition runs [Pending Medicare Behavioral Health Applicants](https://apify.com/actablesite/pending-medicare-behavioral-health-actor) in the buyer's Apify account. It requests one $12 event only after national validation passes; buyer-paid Apify platform usage is separate. The action refuses a complete run without both a token and an explicit $12.25 total-charge cap.

## Quick start: free preview

```yaml
name: Preview pending Medicare behavioral-health records

on:
  workflow_dispatch:

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - id: applicants
        uses: unitedideas/pending-medicare-behavioral-health-action@v1
        with:
          states: CA,TX
      - uses: actions/upload-artifact@v4
        with:
          name: pending-medicare-behavioral-health
          path: ${{ steps.applicants.outputs.output-file }}
```

The preview downloads the current 10-row sample and source receipt from the public [Actor repository](https://github.com/unitedideas/pending-medicare-behavioral-health-actor/tree/main/sample). It validates both contracts, applies the optional state filter, and creates no Apify run or charge. The workflow summary reports the delivered count, current and prior CMS snapshot dates, validated national count, state filter, official methodology, limitations, and optional paid handoff.

## Complete current edition

Create an Apify API token in your own account, store it as the repository secret `APIFY_TOKEN`, set `preview: false`, and explicitly raise the cap:

```yaml
      - id: applicants
        uses: unitedideas/pending-medicare-behavioral-health-action@v1
        with:
          apify-token: ${{ secrets.APIFY_TOKEN }}
          preview: false
          states: CA,TX,FL
          max-total-charge-usd: "12.25"
```

The Actor resolves the current and immediately prior CMS publications, diffs NPIs, enriches new applicants from NPPES, applies the disclosed behavioral-health taxonomy boundary, and validates the national edition before requesting the $12 event. If validation or authorization fails, complete records are not delivered.

## Inputs and outputs

| Input | Default | Meaning |
| --- | --- | --- |
| `apify-token` | empty | Buyer-owned Apify token, required only for a complete edition and supplied through GitHub Secrets. |
| `states` | empty | Optional comma-separated two-letter state or territory codes. |
| `preview` | `true` | Download the current public 10-row sample without an Apify run. |
| `max-total-charge-usd` | `0.10` | Hard cap for an Apify run. Complete editions require at least `12.25`. |
| `output-file` | `pending-medicare-behavioral-health.json` | JSON destination inside the workflow workspace. |

The action returns `record-count` and `output-file`. Free previews also return `current-snapshot` and `prior-snapshot`. Uploading or committing the output is an explicit workflow choice; this action does neither automatically.

## What pending means

CMS publishes these files for first-time Medicare enrollment applications still under contractor review. A record does not prove Medicare approval, enrollment, billing privileges, licensure, credentialing, a new practice, service availability, interest, or readiness to buy. Public NPPES address and telephone fields may be old, shared, or operational. Verify every record before a consequential or contact decision.

Read the [official CMS fee-for-service public provider enrollment methodology](https://data.cms.gov/resources/fee-for-service-public-provider-enrollment-methodology) and inspect the [account-free public sample](https://github.com/unitedideas/pending-medicare-behavioral-health-actor/tree/main/sample) before considering a complete run.

## Security and operating boundary

- The free preview reads only public GitHub files and needs no credential.
- For a complete edition, use the least-privilege Apify token available to your account and store it only in GitHub Secrets.
- GitHub does not provide repository secrets to workflows triggered from untrusted forks by default.
- The action validates state and output-path inputs and fails closed on malformed source contracts or HTTP errors.
- The action does not send email, contact applicants, infer intent, or transmit records anywhere except the public preview source, your selected Apify account for a complete edition, and the workflow runner.

## License

MIT
