const test = require("node:test");
const assert = require("node:assert/strict");
const { activateCourse, completeAndArchivePreviousCourse, lineUsesTurns } = require("../src/monitor-course-operations");

test("force-activating a course leaves earlier dishes and monitor history untouched", () => {
  const order = {
    id: 12,
    activeCourse: 0,
    courseSequence: [1, 2],
    dismissedCoursesByMonitor: { Bar: [3] },
    items: [
      { id: "starter", category: "Starters", course: 0, kitchenStatus: "In preparazione" },
      { id: "drink", category: "Drinks", course: 0, noTurns: true, kitchenStatus: "In preparazione" },
      { id: "main", category: "Mains", course: 1, kitchenStatus: "Da preparare" }
    ]
  };
  const result = activateCourse(order, 1);

  assert.deepEqual(result, { activeCourse: 1 });
  assert.equal(order.items[0].kitchenStatus, "In preparazione");
  assert.equal(order.items[0].tho, undefined);
  assert.equal(order.items[1].kitchenStatus, "In preparazione");
  assert.equal(order.items[2].kitchenStatus, "Da preparare");
  assert.deepEqual(order.dismissedCoursesByMonitor, { Bar: [3] });
  assert.equal(order.dismissedCourses, undefined);
  assert.equal(order.activeCourse, 1);
  assert.deepEqual(order.courseSequence, [2, 1]);
});

test("course routing honors per-category turn overrides and delivery/no-turn lines", () => {
  const settings = {
    categoryMonitors: { Grill: "Brace", Drinks: "Bar" },
    categoryTurns: { Grill: false },
    monitors: [{ name: "Brace", turns: true }, { name: "Bar", turns: true }]
  };
  assert.equal(lineUsesTurns({ category: "Grill", course: 0 }, null, settings), false);
  assert.equal(lineUsesTurns({ category: "Drinks", course: 0 }, null, settings), true);
  assert.equal(lineUsesTurns({ category: "Drinks", noTurns: true }, null, settings), false);
  assert.equal(lineUsesTurns({ category: "Drinks" }, { source: "manual" }, settings), false);
});

test("delivered previous course is completed and archived only for its sequenced monitor", () => {
  const order = {
    activeCourse: 0,
    courseSequence: [1, 2],
    dismissedCoursesByMonitor: { Bar: [3] },
    items: [
      { category: "Starters", course: 0, kitchenStatus: "Da preparare" },
      { category: "Drinks", course: 0, noTurns: true, kitchenStatus: "In preparazione" },
      { category: "Mains", course: 1, kitchenStatus: "Da preparare" }
    ]
  };
  const settings = {
    categoryMonitors: { Starters: "Cucina", Drinks: "Bar", Mains: "Cucina" },
    monitors: [{ name: "Cucina", turns: true }, { name: "Bar", turns: false }]
  };

  const result = completeAndArchivePreviousCourse(order, 1, settings);

  assert.equal(result.completedLines, 1);
  assert.deepEqual(result.monitors, ["Cucina"]);
  assert.equal(order.items[0].kitchenStatus, "Completo");
  assert.equal(order.items[0].tho.kitchen_status, "Completo");
  assert.equal(order.items[1].kitchenStatus, "In preparazione");
  assert.equal(order.items[2].kitchenStatus, "Da preparare");
  assert.deepEqual(order.dismissedCoursesByMonitor, { Bar: [3], Cucina: [0] });
  assert.equal(order.activeCourse, 1);
  assert.deepEqual(order.courseSequence, [2, 1]);
});

test("activation rejects invalid sequence numbers without changing the order", () => {
  const order = { items: [{ category: "Mains", course: 0, kitchenStatus: "In preparazione" }] };
  assert.throws(() => activateCourse(order, 0), /Sequenza successiva non valida/);
  assert.equal(order.items[0].kitchenStatus, "In preparazione");
  assert.equal(order.activeCourse, undefined);
});
