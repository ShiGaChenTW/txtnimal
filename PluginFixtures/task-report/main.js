// Deterministic (no-LLM) task report plugin.
//
// The host evaluates this source, then calls the global run(input) and decodes
// its return value as a PluginPageDocument. All aggregation happens here in JS
// with literal computed values so the host never has to resolve queries.
//
//   input = {
//     reportType: "weekly" | "progress" | "category" | "standup",
//     tasks: [ { id, title, due, completed, lists, tags } ],
//     todayYMD: "YYYY-MM-DD"
//   }
//
// Due dates are canonical "YYYY-MM-DD" strings, so lexicographic comparison
// against todayYMD is a correct chronological comparison.

function node(type, id, extra) {
  var result = { type: type, id: id };
  if (extra) {
    for (var key in extra) {
      if (extra.hasOwnProperty(key) && extra[key] !== undefined && extra[key] !== null) {
        result[key] = extra[key];
      }
    }
  }
  return result;
}

function statCard(id, title, value) {
  return node("statCard", id, { title: title, value: value });
}

function pageDocument(pageID, title, children) {
  return {
    schemaVersion: 1,
    page: node("page", "report-root", { pageID: pageID, title: title, children: children })
  };
}

function taskLine(task) {
  var line = "• " + task.title;
  if (task.due) { line += "（截止 " + task.due + "）"; }
  return line;
}

// Builds a section whose children are one text node per task (or an empty state).
function taskSection(id, title, tasks) {
  var children = [];
  if (tasks.length === 0) {
    children.push(node("emptyState", id + "-empty", { title: "沒有項目" }));
  } else {
    for (var i = 0; i < tasks.length; i++) {
      children.push(node("text", id + "-t" + i, { value: taskLine(tasks[i]) }));
    }
  }
  return node("section", id, { title: title + "（" + tasks.length + "）", children: children });
}

function classify(tasks, today) {
  var overdue = [], dueToday = [], upcoming = [], completed = [], noDue = [];
  for (var i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    if (task.completed) { completed.push(task); continue; }
    if (task.due) {
      if (task.due < today) { overdue.push(task); }
      else if (task.due === today) { dueToday.push(task); }
      else { upcoming.push(task); }
    } else {
      noDue.push(task);
    }
  }
  return { overdue: overdue, today: dueToday, upcoming: upcoming, completed: completed, noDue: noDue };
}

function percent(done, total) {
  if (total <= 0) { return "0%"; }
  return Math.round(done * 100 / total) + "%";
}

// Counts occurrences of each value in a repeated string field (lists or tags),
// preserving first-seen order for stable output.
function countBy(tasks, field) {
  var counts = {}, order = [];
  for (var i = 0; i < tasks.length; i++) {
    var values = tasks[i][field] || [];
    for (var j = 0; j < values.length; j++) {
      var key = values[j];
      if (!counts.hasOwnProperty(key)) { counts[key] = 0; order.push(key); }
      counts[key] += 1;
    }
  }
  return order.map(function (key) { return { label: key, count: counts[key] }; });
}

function groupSection(id, title, items) {
  if (items.length === 0) {
    return node("section", id, {
      title: title,
      children: [node("emptyState", id + "-empty", { title: "沒有資料" })]
    });
  }
  var max = 0;
  for (var i = 0; i < items.length; i++) { if (items[i].count > max) { max = items[i].count; } }
  var children = [];
  for (var j = 0; j < items.length; j++) {
    children.push(node("text", id + "-t" + j, { value: items[j].label + "：" + items[j].count }));
  }
  var normalized = items.map(function (item) {
    return max > 0 ? Math.round(item.count / max * 100) / 100 : 0;
  });
  children.push(node("barChart", id + "-chart", { title: title + " 長條圖", value: normalized.join(",") }));
  return node("section", id, { title: title, children: children });
}

function weeklyReport(tasks, today) {
  var groups = classify(tasks, today);
  var overview = node("section", "weekly-overview", {
    title: "本週概況",
    children: [
      statCard("weekly-stat-overdue", "逾期", String(groups.overdue.length)),
      statCard("weekly-stat-today", "今日到期", String(groups.today.length)),
      statCard("weekly-stat-upcoming", "即將到來", String(groups.upcoming.length)),
      statCard("weekly-stat-completed", "已完成", String(groups.completed.length))
    ]
  });
  return pageDocument("weekly", "任務週報", [
    overview,
    taskSection("weekly-overdue", "逾期", groups.overdue),
    taskSection("weekly-today", "今日到期", groups.today),
    taskSection("weekly-upcoming", "即將到來", groups.upcoming),
    taskSection("weekly-completed", "已完成本週", groups.completed)
  ]);
}

function progressReport(tasks) {
  var groups = {}, order = [], doneTasks = 0;
  for (var i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    if (task.completed) { doneTasks += 1; }
    var names = (task.lists && task.lists.length) ? task.lists : ["未分類"];
    for (var j = 0; j < names.length; j++) {
      var name = names[j];
      if (!groups.hasOwnProperty(name)) { groups[name] = { total: 0, done: 0 }; order.push(name); }
      groups[name].total += 1;
      if (task.completed) { groups[name].done += 1; }
    }
  }
  var overview = node("section", "progress-overview", {
    title: "整體進度",
    children: [
      statCard("progress-stat-total", "任務總數", String(tasks.length)),
      statCard("progress-stat-done", "已完成", String(doneTasks)),
      statCard("progress-stat-rate", "完成率", percent(doneTasks, tasks.length))
    ]
  });
  var listChildren = [];
  for (var k = 0; k < order.length; k++) {
    var group = groups[order[k]];
    listChildren.push(statCard("progress-list-" + k, order[k],
      group.done + "/" + group.total + "（" + percent(group.done, group.total) + "）"));
  }
  if (listChildren.length === 0) {
    listChildren.push(node("emptyState", "progress-empty", { title: "沒有清單" }));
  }
  var listsSection = node("section", "progress-lists", {
    title: "各清單完成率",
    children: listChildren
  });
  return pageDocument("progress", "進度摘要", [overview, listsSection]);
}

function categoryReport(tasks) {
  return pageDocument("category", "分類統計", [
    groupSection("category-tags", "標籤分佈", countBy(tasks, "tags")),
    groupSection("category-lists", "清單分佈", countBy(tasks, "lists"))
  ]);
}

function standupReport(tasks, today) {
  var groups = classify(tasks, today);
  var overview = node("section", "standup-overview", {
    title: "站會概況",
    children: [
      statCard("standup-stat-yesterday", "昨日完成", String(groups.completed.length)),
      statCard("standup-stat-today", "今日到期", String(groups.today.length)),
      statCard("standup-stat-blockers", "阻塞（逾期）", String(groups.overdue.length))
    ]
  });
  return pageDocument("standup", "站會日報", [
    overview,
    taskSection("standup-yesterday", "昨日完成（已完成）", groups.completed),
    taskSection("standup-today", "今日進行", groups.today),
    taskSection("standup-blockers", "阻塞：逾期項目", groups.overdue)
  ]);
}

function run(input) {
  var data = input || {};
  var tasks = data.tasks || [];
  var today = data.todayYMD || "";
  switch (data.reportType) {
    case "progress": return progressReport(tasks);
    case "category": return categoryReport(tasks);
    case "standup": return standupReport(tasks, today);
    default: return weeklyReport(tasks, today);
  }
}
