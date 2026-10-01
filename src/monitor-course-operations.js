function lineUsesTurns(line, order, settings) {
  if (order?.source || line?.noTurns || line?.tho?.no_turns) return false;
  const category = String(line?.category || "").trim();
  const mappedMonitor = settings?.categoryMonitors?.[category] || "Cucina";
  const monitor = (settings?.monitors || []).find(item => item && item.name === mappedMonitor);
  return settings?.categoryTurns && Object.prototype.hasOwnProperty.call(settings.categoryTurns, category)
    ? settings.categoryTurns[category] !== false
    : monitor ? monitor.turns !== false : mappedMonitor !== "Bar";
}

function activateCourse(order, course) {
  const normalizedCourse = Number(course);
  if (!order || !Array.isArray(order.items) || !Number.isInteger(normalizedCourse) || normalizedCourse < 1 || normalizedCourse > 3) {
    throw new Error("Sequenza successiva non valida");
  }

  order.activeCourse = normalizedCourse;
  if (!Array.isArray(order.courseSequence)) order.courseSequence = [];
  order.courseSequence = order.courseSequence.filter(value => Number(value) !== normalizedCourse);
  order.courseSequence.push(normalizedCourse);
  return { activeCourse: normalizedCourse };
}

function completeAndArchivePreviousCourse(order, course, settings) {
  const normalizedCourse = Number(course);
  if (!order || !Array.isArray(order.items) || !Number.isInteger(normalizedCourse) || normalizedCourse < 1 || normalizedCourse > 3) {
    throw new Error("Sequenza successiva non valida");
  }

  const previousCourse = normalizedCourse - 1;
  const previousLines = order.items.filter(line =>
    lineUsesTurns(line, order, settings) && Number(line.course || 0) === previousCourse
  );
  const affectedMonitors = new Set();
  previousLines.forEach(line => {
    line.kitchenStatus = "Completo";
    line.tho = { ...(line.tho || {}), kitchen_status: "Completo" };
    affectedMonitors.add(settings?.categoryMonitors?.[String(line.category || "").trim()] || "Cucina");
  });

  if (!order.dismissedCoursesByMonitor || typeof order.dismissedCoursesByMonitor !== "object" || Array.isArray(order.dismissedCoursesByMonitor)) {
    order.dismissedCoursesByMonitor = {};
  }
  affectedMonitors.forEach(monitorName => {
    if (!Array.isArray(order.dismissedCoursesByMonitor[monitorName])) order.dismissedCoursesByMonitor[monitorName] = [];
    if (!order.dismissedCoursesByMonitor[monitorName].some(value => Number(value) === previousCourse)) {
      order.dismissedCoursesByMonitor[monitorName].push(previousCourse);
    }
  });

  const activation = activateCourse(order, normalizedCourse);
  return { ...activation, previousCourse, completedLines: previousLines.length, monitors: [...affectedMonitors] };
}

module.exports = { activateCourse, completeAndArchivePreviousCourse, lineUsesTurns };
