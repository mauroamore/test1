# Deliveroo Orders Integration Contract

This file records the order webhook behaviour and test constraints to preserve
during consolidation for production.

## Webhook acknowledgement

- Receive `order.new` and `order.status_update` events on the configured Orders
  webhook.
- Validate the Deliveroo signature when configured.
- Persist the raw JSON payload before business processing.
- Always return HTTP 2xx with valid JSON quickly; database or downstream API
  failures must not turn a received webhook into a timeout.
- Webhook delivery can be retried. Processing must be idempotent by external
  order ID and event/status combination.

## Order lifecycle

1. On `order.new`, store the complete payload and create the local order in a
   pending state.
2. Validate all item and modifier PLUs.
3. Call Deliveroo `sync_status` with `accepted` when the order can be handled.
4. Call `sync_status` with `rejected` and a non-empty fail reason when it cannot
   be handled, especially for missing or mismatched PLUs.
5. Do not send the order to the kitchen before the configured cancellation
   protection window has elapsed. The cancellation test permits cancellation
   shortly after acceptance.
6. When the order is accepted, release it to the kitchen and keep later status
   updates independent from the original webhook request.

## Required order data

- Preserve the complete original payload, including customer, notes, totals,
  discounts, meal cards, fulfillment type, scheduled times and remake details.
- Prices are fractional minor units with a currency code.
- `fulfillment_type` may be `deliveroo`, `restaurant` or `customer`.
- Scheduled orders must be held until the requested preparation time. Orders
  scheduled in the past are treated as ASAP.
- Partial meal-card payments must not change the order total calculation.

## PLU validation

- Normal item IDs use the numeric part after `MU` to match the local product ID.
- Normal modifier IDs use the numeric part after `OM` to match the local
  ingredient ID.
- `deliveroo_menu_mapping` is used only for exceptional/non-standard IDs.
- Validate all item IDs in one batched database query, not one query per item.
- Compare the returned IDs and names against the payload; an equal row count is
  not sufficient if names are swapped.
- Ordering both result sets by numeric ID allows deterministic index-by-index
  comparison.
- Missing PLUs require a rejected/fail `sync_status` with a meaningful reason.

## Status events

- `order.status_update` with `accepted` must be acknowledged and must not create
  a duplicate order.
- Cancellation is a final state unless the platform explicitly sends a remake.
- Redelivery/remake orders have a new external order ID and must be stored as a
  separate order while retaining the remake relationship from the payload.
- Rejected orders are final and must remain visible in the audit history.

## Preparation stages

When the operator workflow is enabled, send stages in this order:

1. `in_kitchen`
2. `ready_for_collection_soon`
3. `ready_for_collection`
4. `collected`

The integration must not advance stages automatically in production merely to
pass a sandbox test. Operator actions or an explicit configured automation must
drive the transitions.

## Reliability requirements

- Use short connection and command timeouts.
- Queue non-critical processing after acknowledging Deliveroo.
- Retry transient API/database failures with bounded backoff.
- Record request, response status, response body, order ID and correlation ID
  in a process log, never credentials.
- Keep order receipt and order processing logs separate.
- Use a shared database connection factory and a shared HTTP/OAuth client.

## Historical test constraints

The sandbox tests demonstrated that successful receipt alone is not enough:
Deliveroo also validates the exact `sync_status` request, including failure
reasons and subsequent preparation-stage calls. Preserve the raw test payloads
and responses as fixtures before refactoring the handlers.

Test-only timers, dummy operator actions and fallback menu IDs must be isolated
behind an explicit sandbox flag and excluded from production behaviour.
