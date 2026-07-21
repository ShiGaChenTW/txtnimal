function run(input) {
  return {
    type: "hostCommand",
    command: "tasks.reschedule",
    taskIDs: input.taskIDs,
    due: input.tomorrow,
    expectedRevision: input.revision
  };
}
