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
    page: node("page", "analytics-root", { pageID: pageID, title: title, children: children })
  };
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

function percent(done, total) {
  if (total <= 0) { return "0%"; }
  return Math.round(done * 100 / total) + "%";
}

function formatNumber(value) {
  if (value === Math.round(value)) { return String(Math.round(value)); }
  return String(Math.round(value * 100) / 100);
}

function normalizeCounts(items) {
  var normalized = [];
  var max = 0;
  for (var i = 0; i < items.length; i++) {
    if (items[i].count > max) { max = items[i].count; }
  }
  for (var j = 0; j < items.length; j++) {
    normalized.push(max > 0 ? Math.round(items[j].count / max * 100) / 100 : 0);
  }
  return normalized;
}

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
  var items = [];
  for (var k = 0; k < order.length; k++) {
    items.push({ label: order[k], count: counts[order[k]] });
  }
  return items;
}

function listStats(tasks) {
  var groups = {}, order = [];
  for (var i = 0; i < tasks.length; i++) {
    var values = tasks[i].lists || [];
    for (var j = 0; j < values.length; j++) {
      var key = values[j];
      if (!groups.hasOwnProperty(key)) {
        groups[key] = { label: key, total: 0, done: 0 };
        order.push(key);
      }
      groups[key].total += 1;
      if (tasks[i].completed) { groups[key].done += 1; }
    }
  }
  var items = [];
  for (var k = 0; k < order.length; k++) {
    items.push(groups[order[k]]);
  }
  return items;
}

function hasCompletionDates(tasks) {
  for (var i = 0; i < tasks.length; i++) {
    if (tasks[i].done) { return true; }
  }
  return false;
}

function weeklyTrend(tasks, today, weeks) {
  var counts = [];
  var labels = [];
  var total = 0;
  var i, j;
  for (i = 0; i < weeks; i++) {
    counts.push(0);
  }
  for (j = 0; j < tasks.length; j++) {
    var done = tasks[j].done;
    if (!done) { continue; }
    var age = daysBetween(done, today);
    if (age < 0 || age >= weeks * 7) { continue; }
    var bucket = weeks - 1 - Math.floor(age / 7);
    counts[bucket] += 1;
    total += 1;
  }
  for (i = 0; i < weeks; i++) {
    var endOffset = -((weeks - 1 - i) * 7);
    var startOffset = endOffset - 6;
    var start = addDays(today, startOffset);
    var end = addDays(today, endOffset);
    labels.push({ start: start, end: end, count: counts[i] });
  }
  return { counts: counts, labels: labels, total: total };
}

function overviewSection(tasks) {
  var completed = 0;
  for (var i = 0; i < tasks.length; i++) {
    if (tasks[i].completed) { completed += 1; }
  }
  var total = tasks.length;
  var open = total - completed;
  return node("section", "analytics-overview", {
    title: "總覽",
    children: [
      statCard("analytics-stat-total", "任務總數", String(total)),
      statCard("analytics-stat-open", "進行中", String(open)),
      statCard("analytics-stat-completed", "已完成", String(completed)),
      statCard("analytics-stat-rate", "完成率", percent(completed, total))
    ]
  });
}

function listsSection(tasks) {
  var items = listStats(tasks);
  var children = [];
  var i;
  if (items.length === 0) {
    children.push(node("emptyState", "analytics-lists-empty", { title: "沒有清單" }));
  } else {
    for (i = 0; i < items.length; i++) {
      children.push(statCard("analytics-list-" + i, items[i].label,
        items[i].done + "/" + items[i].total + "（" + percent(items[i].done, items[i].total) + "）"));
    }
    for (i = 0; i < items.length; i++) {
      children.push(node("text", "analytics-lists-label-" + i, {
        value: items[i].label + "：" + items[i].total
      }));
    }
    children.push(node("barChart", "analytics-lists-chart", {
      title: "清單任務量",
      value: normalizeCounts(items.map(function (item) {
        return { count: item.total };
      })).join(",")
    }));
  }
  return node("section", "analytics-lists", {
    title: "依清單完成率",
    children: children
  });
}

function tagsSection(tasks) {
  var items = countBy(tasks, "tags");
  var children = [];
  var i;
  if (items.length === 0) {
    children.push(node("emptyState", "analytics-tags-empty", { title: "沒有標籤" }));
  } else {
    for (i = 0; i < items.length; i++) {
      children.push(node("text", "analytics-tags-label-" + i, {
        value: items[i].label + "：" + items[i].count
      }));
    }
    children.push(node("barChart", "analytics-tags-chart", {
      title: "標籤分佈",
      value: normalizeCounts(items).join(",")
    }));
  }
  return node("section", "analytics-tags", {
    title: "依標籤分佈",
    children: children
  });
}

function trendSection(tasks, today) {
  var weeks = 8;
  var completionDatesReady = hasCompletionDates(tasks);
  var trendChildren = [
    statCard("analytics-stat-velocity", "Velocity", "—")
  ];
  var trend;
  var i;

  if (completionDatesReady) {
    trend = weeklyTrend(tasks, today, weeks);
    trendChildren[0] = statCard("analytics-stat-velocity", "Velocity",
      formatNumber(trend.total / weeks));
    for (i = 0; i < trend.labels.length; i++) {
      trendChildren.push(node("text", "analytics-trend-label-" + i, {
        value: trend.labels[i].start + "～" + trend.labels[i].end + "：" + trend.labels[i].count
      }));
    }
    trendChildren.push(node("barChart", "analytics-trend-chart", {
      title: "最近 " + weeks + " 週完成趨勢",
      value: normalizeCounts(trend.counts.map(function (count) {
        return { count: count };
      })).join(",")
    }));
  } else {
    trendChildren.push(node("emptyState", "analytics-trend-empty", { title: "需要完成日期資料" }));
  }

  return node("section", "analytics-trend", {
    title: "完成趨勢",
    children: trendChildren
  });
}

function run(input) {
  var data = input || {};
  var tasks = data.tasks || [];
  var today = data.todayYMD || "";
  return pageDocument("analytics", "分析儀表板", [
    overviewSection(tasks),
    listsSection(tasks),
    tagsSection(tasks),
    trendSection(tasks, today)
  ]);
}
