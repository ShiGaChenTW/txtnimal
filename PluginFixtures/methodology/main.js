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
    page: node("page", "methodology-root", { pageID: pageID, title: title, children: children })
  };
}

function taskLine(task) {
  var line = "• " + task.title;
  if (task.due) { line += "（截止 " + task.due + "）"; }
  return line;
}

function taskNodes(id, tasks) {
  var children = [];
  var i;
  if (tasks.length === 0) {
    children.push(node("emptyState", id + "-empty", { title: "沒有項目" }));
  } else {
    for (i = 0; i < tasks.length; i++) {
      children.push(node("text", id + "-t" + i, { value: taskLine(tasks[i]) }));
    }
  }
  return children;
}

function taskSection(id, title, tasks) {
  return node("section", id, {
    title: title + "（" + tasks.length + "）",
    children: taskNodes(id, tasks)
  });
}

function overviewSection(id, title, cards) {
  return node("section", id, { title: title, children: cards });
}

function hasTag(task, tag) {
  var tags = task.tags || [];
  var plain = tag.charAt(0) === "@" ? tag.slice(1) : tag;
  var i;
  for (i = 0; i < tags.length; i++) {
    if (tags[i] === plain || tags[i] === tag) { return true; }
  }
  return false;
}

function hasAnyContext(task) {
  var tags = task.tags || [];
  return tags.length > 0;
}

function firstList(task) {
  var lists = task.lists || [];
  return lists.length > 0 ? lists[0] : null;
}

function isValidQuadrant(value) {
  return typeof value === "number" && value === Math.floor(value) && value >= 1 && value <= 4;
}

function paraReport(tasks) {
  var archive = [];
  var areas = [];
  var resources = [];
  var projects = [];
  var inbox = [];
  var i, task;

  for (i = 0; i < tasks.length; i++) {
    task = tasks[i];
    if (task.completed) { archive.push(task); }
    else if (hasTag(task, "area")) { areas.push(task); }
    else if (hasTag(task, "resource")) { resources.push(task); }
    else if ((task.lists || []).length > 0) { projects.push(task); }
    else { inbox.push(task); }
  }

  return pageDocument("para", "PARA 方法論", [
    overviewSection("para-overview", "PARA 總覽", [
      statCard("para-stat-archive", "Archive 封存", String(archive.length)),
      statCard("para-stat-areas", "Areas 領域", String(areas.length)),
      statCard("para-stat-resources", "Resources 資源", String(resources.length)),
      statCard("para-stat-projects", "Projects 專案", String(projects.length)),
      statCard("para-stat-inbox", "Inbox 收件匣", String(inbox.length))
    ]),
    taskSection("para-archive", "Archive 封存", archive),
    taskSection("para-areas", "Areas 領域", areas),
    taskSection("para-resources", "Resources 資源", resources),
    taskSection("para-projects", "Projects 專案", projects),
    taskSection("para-inbox", "Inbox 收件匣", inbox)
  ]);
}

function gtdProjectsSection(tasks) {
  var groups = {};
  var order = [];
  var i, j, list;

  for (i = 0; i < tasks.length; i++) {
    for (j = 0; j < (tasks[i].lists || []).length; j++) {
      list = tasks[i].lists[j];
      if (!groups.hasOwnProperty(list)) {
        groups[list] = [];
        order.push(list);
      }
      groups[list].push(tasks[i]);
    }
  }

  var children = [statCard("gtd-projects-total", "Projects 專案", String(tasks.length))];
  if (order.length === 0) {
    children.push(node("emptyState", "gtd-projects-empty", { title: "沒有項目" }));
  } else {
    for (i = 0; i < order.length; i++) {
      children.push(taskSection("gtd-project-" + i, "+" + order[i], groups[order[i]]));
    }
  }

  return node("section", "gtd-projects", {
    title: "Projects 專案（" + tasks.length + "）",
    children: children
  });
}

function gtdReport(tasks) {
  var waiting = [];
  var someday = [];
  var next = [];
  var projects = [];
  var inbox = [];
  var i, task, lists;

  for (i = 0; i < tasks.length; i++) {
    task = tasks[i];
    if (task.completed) { continue; }
    lists = task.lists || [];
    if (hasTag(task, "waiting")) { waiting.push(task); }
    else if (hasTag(task, "someday")) { someday.push(task); }
    else if (hasAnyContext(task)) { next.push(task); }
    else if (lists.length > 0) { projects.push(task); }
    else { inbox.push(task); }
  }

  return pageDocument("gtd", "GTD 方法論", [
    overviewSection("gtd-overview", "GTD 總覽", [
      statCard("gtd-stat-waiting", "Waiting For 等待中", String(waiting.length)),
      statCard("gtd-stat-someday", "Someday/Maybe 將來也許", String(someday.length)),
      statCard("gtd-stat-next", "Next Actions 下一步", String(next.length)),
      statCard("gtd-stat-projects", "Projects 專案", String(projects.length)),
      statCard("gtd-stat-inbox", "Inbox 收件匣", String(inbox.length))
    ]),
    taskSection("gtd-waiting", "Waiting For 等待中", waiting),
    taskSection("gtd-someday", "Someday/Maybe 將來也許", someday),
    taskSection("gtd-next", "Next Actions 下一步", next),
    gtdProjectsSection(projects),
    taskSection("gtd-inbox", "Inbox 收件匣", inbox)
  ]);
}

function eisenhowerReport(tasks) {
  var hasQuadrant = false;
  var i, task;
  for (i = 0; i < tasks.length; i++) {
    if (isValidQuadrant(tasks[i].q)) {
      hasQuadrant = true;
      break;
    }
  }

  if (!hasQuadrant) {
    return pageDocument("eisenhower", "艾森豪矩陣", [
      node("emptyState", "eisenhower-missing-q", { title: "需要象限(q)資料" })
    ]);
  }

  var q1 = [];
  var q2 = [];
  var q3 = [];
  var q4 = [];
  var pool = [];

  for (i = 0; i < tasks.length; i++) {
    task = tasks[i];
    if (task.q === 1) { q1.push(task); }
    else if (task.q === 2) { q2.push(task); }
    else if (task.q === 3) { q3.push(task); }
    else if (task.q === 4) { q4.push(task); }
    else if (!task.completed) { pool.push(task); }
  }

  return pageDocument("eisenhower", "艾森豪矩陣", [
    overviewSection("eisenhower-overview", "象限總覽", [
      statCard("eisenhower-stat-q1", "q1 Do", String(q1.length)),
      statCard("eisenhower-stat-q2", "q2 Schedule", String(q2.length)),
      statCard("eisenhower-stat-q3", "q3 Delegate", String(q3.length)),
      statCard("eisenhower-stat-q4", "q4 Delete", String(q4.length)),
      statCard("eisenhower-stat-pool", "未歸位池", String(pool.length))
    ]),
    taskSection("eisenhower-q1", "q1 Do｜立即執行", q1),
    taskSection("eisenhower-q2", "q2 Schedule｜排程處理", q2),
    taskSection("eisenhower-q3", "q3 Delegate｜委派追蹤", q3),
    taskSection("eisenhower-q4", "q4 Delete｜刪除忽略", q4),
    taskSection("eisenhower-pool", "未歸位池", pool)
  ]);
}

function run(input) {
  var data = input || {};
  var tasks = data.tasks || [];
  switch (data.reportType) {
    case "eisenhower": return eisenhowerReport(tasks);
    case "para": return paraReport(tasks);
    case "gtd": return gtdReport(tasks);
    default: return gtdReport(tasks);
  }
}
