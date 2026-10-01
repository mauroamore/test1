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

module.exports = { activateCourse, lineUsesTurns };
