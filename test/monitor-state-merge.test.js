const test = require("node:test");
const assert = require("node:assert/strict");
const { mergeMonitorFields } = require("../src/monitor-state-merge");

test("preserves monitor statuses and dismissed courses in a stale management snapshot", () => {
  const current = {
    dismissedCourses: [0],
    items: [
      { key: "dish::course=0", id: "dish", name: "Dish", course: 0, price: 7, kitchenStatus: "Completo" },
      { key: "dish2::course=1", id: "dish2", name: "Dish 2", course: 1, price: 8, kitchenStatus: "In preparazione" }
    ]
  };
  const incoming = {
    dismissedCourses: [],
    items: [
      { key: "dish::rebuilt-course=0", id: "dish", name: "Dish", course: 0, price: 7, kitchenStatus: "Da preparare" },
      { key: "dish2::course=1", id: "dish2", name: "Dish 2", course: 1, price: 8, kitchenStatus: "Da preparare" },
      { key: "new::course=1", id: "new", name: "New dish", course: 1, price: 9, kitchenStatus: "Da preparare" }
    ]
  };

  const result = mergeMonitorFields(current, incoming);

  assert.equal(result.preservedStatuses, 2);
  assert.deepEqual(incoming.dismissedCourses, [0]);
  assert.equal(incoming.items[0].kitchenStatus, "Completo");
  assert.equal(incoming.items[0].tho.kitchen_status, "Completo");
  assert.equal(incoming.items[1].kitchenStatus, "In preparazione");
  assert.equal(incoming.items[1].tho.kitchen_status, "In preparazione");
  assert.equal(incoming.items[2].kitchenStatus, "Da preparare");
});

test("preserves a closed monitor order until a new line reopens it", () => {
  const current = {
    kitchenClosed: true,
    kitchenClosedAt: "2026-09-26T10:00:00.000Z",
    items: [{ key: "dish", id: "dish", name: "Dish", course: 1, price: 7, kitchenStatus: "Completo" }]
  };
  const incoming = { kitchenClosed: false, items: [{ key: "dish", id: "dish", name: "Dish", course: 1, price: 7 }] };
  mergeMonitorFields(current, incoming);
  assert.equal(incoming.kitchenClosed, true);
  assert.equal(incoming.kitchenClosedAt, current.kitchenClosedAt);
});
