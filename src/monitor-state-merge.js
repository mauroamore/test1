const ADVANCED_MONITOR_STATUSES = new Set(["In preparazione", "Completo"]);

function normalizedValue(value) {
  return String(value == null ? "" : value).trim().toLowerCase();
}

function variationIdentity(value) {
  if (!Array.isArray(value)) return "";
  return value
    .map(item => typeof item === "object" && item !== null
      ? JSON.stringify(item)
      : String(item))
    .sort()
    .join(",");
}

// The key is normally enough, but a management snapshot created before a new
// course was added can rebuild it. The fallback keeps the line attached to
// its monitor status without relying on the generated key format.
function lineIdentityCandidates(line) {
  if (!line || typeof line !== "object") return [];
  const candidates = [];
  if (line.key != null && String(line.key)) candidates.push(`key:${line.key}`);
  candidates.push([
    "line",
    normalizedValue(line.id),
    line.course == null ? 1 : Number(line.course),
    normalizedValue(line.name || line.originalName),
    Number(line.price || 0).toFixed(2),
    variationIdentity(line.minusVariations),
    variationIdentity(line.plusVariations)
  ].join("|"));
  return candidates;
}

function mergeUniqueNumbers(...values) {
  return [...new Set(values.flatMap(value => Array.isArray(value) ? value : [])
    .map(item => Number(item))
    .filter(Number.isFinite))];
}

function mergeMonitorFields(currentOrder, incomingOrder) {
  const result = {
    preservedStatuses: 0,
    preservedDismissedCourses: false,
    preservedClosed: false
  };
  if (!currentOrder || typeof currentOrder !== "object" || !incomingOrder || typeof incomingOrder !== "object") return result;

  const incomingDismissedBeforeMerge = mergeUniqueNumbers(incomingOrder.dismissedCourses);
  const dismissedCourses = mergeUniqueNumbers(currentOrder.dismissedCourses, incomingOrder.dismissedCourses);
  const currentDismissed = mergeUniqueNumbers(currentOrder.dismissedCourses);
  if (dismissedCourses.length || Array.isArray(currentOrder.dismissedCourses) || Array.isArray(incomingOrder.dismissedCourses)) {
    incomingOrder.dismissedCourses = dismissedCourses;
    result.preservedDismissedCourses = currentDismissed.some(course => !incomingDismissedBeforeMerge.includes(course));
  }

  const currentItems = Array.isArray(currentOrder.items) ? currentOrder.items : [];
  const incomingItems = Array.isArray(incomingOrder.items) ? incomingOrder.items : [];
  const currentByIdentity = new Map();
  currentItems.forEach(line => lineIdentityCandidates(line).forEach(identity => {
    const lines = currentByIdentity.get(identity) || [];
    lines.push(line);
    currentByIdentity.set(identity, lines);
  }));
  const usedCurrentLines = new Set();
  const unmatchedIncomingLines = [];

  incomingItems.forEach(line => {
    const previous = lineIdentityCandidates(line)
      .flatMap(identity => currentByIdentity.get(identity) || [])
      .find(candidate => !usedCurrentLines.has(candidate));
    if (!previous) {
      unmatchedIncomingLines.push(line);
      return;
    }
    usedCurrentLines.add(previous);
    const previousStatus = String(previous.kitchenStatus || previous.tho?.kitchen_status || "");
    const incomingStatus = String(line.kitchenStatus || line.tho?.kitchen_status || "");
    if (ADVANCED_MONITOR_STATUSES.has(previousStatus) && incomingStatus !== previousStatus) {
      line.kitchenStatus = previousStatus;
      line.tho = { ...(line.tho || {}), kitchen_status: previousStatus };
      result.preservedStatuses += 1;
    }
  });

  // A monitor can archive an entire order. Keep that tombstone when a stale
  // full-state snapshot contains the same lines; a genuinely new line is the
  // explicit signal that the order was reopened by the operator.
  if (currentOrder.kitchenClosed === true && unmatchedIncomingLines.length === 0) {
    incomingOrder.kitchenClosed = true;
    if (currentOrder.kitchenClosedAt) incomingOrder.kitchenClosedAt = currentOrder.kitchenClosedAt;
    result.preservedClosed = true;
  }
  if (currentOrder.deliveryDismissed === true && unmatchedIncomingLines.length === 0) {
    incomingOrder.deliveryDismissed = true;
  }
  return result;
}

function mergeMonitorFieldsInCollections(currentCollections, incomingCollections) {
  const currentById = new Map();
  for (const collection of currentCollections || []) {
    for (const order of Array.isArray(collection) ? collection : []) {
      if (order && order.id != null) currentById.set(String(order.id), order);
    }
  }
  const summary = { orders: 0, preservedStatuses: 0, preservedDismissedCourses: 0, preservedClosed: 0 };
  for (const collection of incomingCollections || []) {
    for (const order of Array.isArray(collection) ? collection : []) {
      if (!order || order.id == null) continue;
      const result = mergeMonitorFields(currentById.get(String(order.id)), order);
      if (result.preservedStatuses || result.preservedDismissedCourses || result.preservedClosed) summary.orders += 1;
      summary.preservedStatuses += result.preservedStatuses;
      summary.preservedDismissedCourses += result.preservedDismissedCourses ? 1 : 0;
      summary.preservedClosed += result.preservedClosed ? 1 : 0;
    }
  }
  return summary;
}

module.exports = { mergeMonitorFields, mergeMonitorFieldsInCollections };
