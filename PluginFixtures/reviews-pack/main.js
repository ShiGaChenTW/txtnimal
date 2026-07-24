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
    page: node("page", "reviews-root", { pageID: pageID, title: title, children: children })
  };
}

function taskLine(task) {
  var line = "• " + task.title;
  if (task.due) { line += "（截止 " + task.due + "）"; }
  return line;
}

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

function ymdToUTC(ymd) {
  var p = ymd.split("-");
  return Date.UTC(parseInt(p[0], 10), parseInt(p[1], 10) - 1, parseInt(p[2], 10));
}

function addDays(ymd, n) {
  var d = new Date(ymdToUTC(ymd) + n * 86400000);
  var mm = d.getUTCMonth() + 1, dd = d.getUTCDate();
  return d.getUTCFullYear() + "-" + (mm < 10 ? "0" + mm : mm) + "-" + (dd < 10 ? "0" + dd : dd);
}

function daysBetween(fromYMD, toYMD) {
  return Math.floor((ymdToUTC(toYMD) - ymdToUTC(fromYMD)) / 86400000);
}

function incompleteTasks(tasks) {
  var out = [];
  for (var i = 0; i < tasks.length; i++) {
    if (!tasks[i].completed) { out.push(tasks[i]); }
  }
  return out;
}

function weeklyReport(tasks, today) {
  var overdue = [], dueToday = [], upcoming = [], completed = [];
  var upperBound = addDays(today, 7);
  for (var i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    if (task.completed) {
      completed.push(task);
      continue;
    }
    if (!task.due) { continue; }
    if (task.due < today) { overdue.push(task); }
    else if (task.due === today) { dueToday.push(task); }
    else if (task.due <= upperBound) { upcoming.push(task); }
  }
  return pageDocument("weekly", "週回顧", [
    node("section", "weekly-overview", {
      title: "週回顧",
      children: [
        statCard("weekly-stat-overdue", "逾期", String(overdue.length)),
        statCard("weekly-stat-today", "今日到期", String(dueToday.length)),
        statCard("weekly-stat-upcoming", "未來七天", String(upcoming.length)),
        statCard("weekly-stat-completed", "本週已完成", String(completed.length))
      ]
    }),
    taskSection("weekly-overdue", "逾期", overdue),
    taskSection("weekly-today", "今日到期", dueToday),
    taskSection("weekly-upcoming", "未來七天", upcoming),
    taskSection("weekly-completed", "本週已完成", completed)
  ]);
}

function dailyReport(tasks, today) {
  var dueToday = [], overdue = [], noDue = [];
  var incomplete = incompleteTasks(tasks);
  for (var i = 0; i < incomplete.length; i++) {
    var task = incomplete[i];
    if (task.due === today) { dueToday.push(task); }
    else if (task.due && task.due < today) { overdue.push(task); }
    else if (!task.due) { noDue.push(task); }
  }
  return pageDocument("daily", "日回顧", [
    node("section", "daily-overview", {
      title: "日回顧",
      children: [
        statCard("daily-stat-today", "今日到期", String(dueToday.length)),
        statCard("daily-stat-overdue", "逾期（阻塞）", String(overdue.length)),
        statCard("daily-stat-nodue", "無期限待處理", String(noDue.length))
      ]
    }),
    taskSection("daily-today", "今日到期", dueToday),
    taskSection("daily-overdue", "逾期（阻塞）", overdue),
    taskSection("daily-nodue", "無期限待處理", noDue)
  ]);
}

function stalledReport(tasks, today) {
  var hasCreated = false;
  for (var i = 0; i < tasks.length; i++) {
    if (tasks[i].created) {
      hasCreated = true;
      break;
    }
  }
  if (!hasCreated) {
    return pageDocument("stalled", "停滯偵測", [
      node("section", "stalled-section", {
        title: "停滯偵測",
        children: [node("emptyState", "stalled-need-created", { title: "需要 created 日期資料" })]
      })
    ]);
  }

  var stalled = [];
  for (var j = 0; j < tasks.length; j++) {
    var task = tasks[j];
    if (task.completed || !task.created) { continue; }
    var age = daysBetween(task.created, today);
    if (age >= 14) { stalled.push({ task: task, age: age, index: j }); }
  }
  stalled.sort(function (a, b) {
    if (a.age !== b.age) { return b.age - a.age; }
    return a.index - b.index;
  });

  var children = [];
  if (stalled.length === 0) {
    children.push(node("emptyState", "stalled-list-empty", { title: "沒有停滯任務" }));
  } else {
    for (var k = 0; k < stalled.length; k++) {
      children.push(node("text", "stalled-list-t" + k, {
        value: taskLine(stalled[k].task) + "（停滯 " + stalled[k].age + " 天）"
      }));
    }
  }
  return pageDocument("stalled", "停滯偵測", [
    node("section", "stalled-overview", {
      title: "停滯偵測",
      children: [statCard("stalled-stat-count", "停滯任務", String(stalled.length))]
    }),
    node("section", "stalled-list", {
      title: "停滯任務（" + stalled.length + "）",
      children: children
    })
  ]);
}

function run(input) {
  var data = input || {};
  var tasks = data.tasks || [];
  var today = data.todayYMD || "";
  switch (data.reportType) {
    case "daily": return dailyReport(tasks, today);
    case "stalled": return stalledReport(tasks, today);
    case "weekly": return weeklyReport(tasks, today);
    default: return weeklyReport(tasks, today);
  }
}
