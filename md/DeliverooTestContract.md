# Deliveroo Integration Test Contract

This file records the sandbox behaviour and constraints that must remain valid
when the Deliveroo integration is consolidated for production.

## Environment

- Sandbox API base: `https://api-sandbox.developers.deliveroo.com`
- OAuth token endpoint: `https://auth-sandbox.developers.deliveroo.com/oauth2/token`
- Menu API base: `/menu/v3`
- Brand: configured externally; never hard-code credentials in source files.
- Site: configured externally.

## Menu V3 flow

1. Call `PUT /menu/v3/brands/{brand_id}/menus/{menu_id}` with no body.
2. Upload the complete JSON document to the returned presigned S3 URL.
   The URL expires quickly, so upload immediately and do not reuse it.
3. Call `POST /menu/v3/brands/{brand_id}/jobs` with:

```json
{"action":"publish_menu_to_live","params":{"menu_id":"<menu_id>"}}
```

4. Store the returned `job_id` and use that exact ID for
   `GET /menu/v3/brands/{brand_id}/jobs/{job_id}`.
5. Poll the job until it reaches a terminal state.
6. Wait for `menu.upload_result` before changing stock on a newly uploaded
   menu.

## Required menu fields

- Root `menu.currency_code` is required, for example `EUR`.
- Every item needs an ID, name, operational name, PLU, description and category.
- Prices are integer minor units.
- Categories must reference item IDs.
- Menu V3 test payloads required at least 100 items of type `ITEM`.
- Test payloads required categories, modifiers, dietary types, images and
  valid mealtimes depending on the scenario.
- Image URLs must be publicly reachable and return valid `HEAD` metadata,
  including `ETag` or `Last-Modified` where required.

## Webhooks

- Menu callbacks use event `menu.upload_result`.
- Respond immediately with HTTP 2xx and a valid JSON body.
- Verify Deliveroo signature headers in production.
- Persist the raw payload, headers, path and timestamp before asynchronous
  processing. Logging failures must not prevent the 2xx acknowledgement.
- Duplicate callbacks are possible; processing must be idempotent.

## Unavailability constraints

- POST individual updates changes only explicitly listed items.
- PUT replaces the complete state; omitted items become available.
- For PUT, GET the current state first when preserving tablet changes.
- Respect the documented rate limit and batch changes where possible.
- After a new menu upload, wait for `menu.upload_result` before updating stock.

## Important sandbox history

The following IDs are retained as historical references only. Production code
must never depend on them:

- `thai-princess-upload-test-20260726-05`
- `thai-princess-upload-test-20260727-01`

Successful examples included HTTP 200 for S3 upload, job creation, job status,
menu fetch and menu webhook acknowledgement. A recurring failure was caused by
placing `currency_code` inside `price_info`; the correct location is the root
`menu` object.

## Consolidation rule

Test-only helpers such as `scenario-item-*`, artificial revisions and fallback
fixtures must be isolated behind an explicit sandbox/test switch and excluded
from production menu generation.
