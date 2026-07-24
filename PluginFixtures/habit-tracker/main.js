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
    page: node("page", "habit-root", { pageID: pageID, title: title, children: children })
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

function habitsSeed() {
  return [
    { id: "water", name: "喝水" },
    { id: "exercise", name: "運動" },
    { id: "reading", name: "閱讀" }
  ];
}

function parseCheckins(raw) {
  var arr = [];
  try {
    arr = JSON.parse(raw);
    if (!(arr instanceof Array)) { arr = []; }
  } catch (e) {
    arr = [];
  }
  return arr;
}

function sortUniqueDates(dates) {
  var seen = {};
  var out = [];
  var i;
  for (i = 0; i < dates.length; i++) {
    if (typeof dates[i] !== "string") { continue; }
    if (!seen.hasOwnProperty(dates[i])) {
      seen[dates[i]] = true;
      out.push(dates[i]);
    }
  }
  out.sort();
  return out;
}

function buildDateSet(dates) {
  var set = {};
  var i;
  for (i = 0; i < dates.length; i++) {
    set[dates[i]] = true;
  }
  return set;
}

function currentStreak(dateSet, today) {
  var anchor = dateSet[today] ? today : addDays(today, -1);
  var count = 0;
  var cursor = anchor;
  if (!dateSet[anchor]) { return 0; }
  while (dateSet[cursor]) {
    count += 1;
    cursor = addDays(cursor, -1);
  }
  return count;
}

function longestStreak(sortedDates) {
  var best = 0;
  var run = 0;
  var i;
  for (i = 0; i < sortedDates.length; i++) {
    if (i === 0 || daysBetween(sortedDates[i - 1], sortedDates[i]) !== 1) {
      run = 1;
    } else {
      run += 1;
    }
    if (run > best) { best = run; }
  }
  return best;
}

function weekCount(dateSet, today) {
  var count = 0;
  var i, day;
  for (i = 0; i < 7; i++) {
    day = addDays(today, i - 6);
    if (dateSet[day]) { count += 1; }
  }
  return count;
}

function chartValue(dateSet, today) {
  var values = [];
  var i, day;
  for (i = 0; i < 7; i++) {
    day = addDays(today, i - 6);
    values.push(dateSet[day] ? "1" : "0");
  }
  return values.join(",");
}

function kvSetAction(key, value) {
  return {
    type: "kvSet",
    command: "storage.kv.set",
    key: key,
    value: value
  };
}

function habitSection(habit, kv, today) {
  var key = "checkins:" + habit.id;
  var sortedDates = sortUniqueDates(parseCheckins(kv[key]));
  var dateSet = buildDateSet(sortedDates);
  var todayChecked = !!dateSet[today];
  var nextDates;
  if (todayChecked) {
    nextDates = [];
    for (var i = 0; i < sortedDates.length; i++) {
      if (sortedDates[i] !== today) { nextDates.push(sortedDates[i]); }
    }
  } else {
    nextDates = sortUniqueDates(sortedDates.concat([today]));
  }

  return node("section", "habit-" + habit.id + "-section", {
    title: habit.name,
    children: [
      statCard("habit-" + habit.id + "-current", "目前連續", String(currentStreak(dateSet, today))),
      statCard("habit-" + habit.id + "-longest", "最長連續", String(longestStreak(sortedDates))),
      statCard("habit-" + habit.id + "-week", "本週打卡", String(weekCount(dateSet, today))),
      node("barChart", "habit-" + habit.id + "-chart", {
        title: "近 7 天",
        value: chartValue(dateSet, today)
      }),
      node("text", "habit-" + habit.id + "-status", {
        value: todayChecked ? "今日已打卡" : "今日待打卡"
      }),
      node("button", "habit-" + habit.id + "-button", {
        title: todayChecked ? "取消今日打卡" : "打卡",
        action: kvSetAction(key, JSON.stringify(nextDates))
      })
    ]
  });
}

function overviewSection(habits, kv, today) {
  var doneToday = 0;
  var i, key, dates;
  for (i = 0; i < habits.length; i++) {
    key = "checkins:" + habits[i].id;
    dates = sortUniqueDates(parseCheckins(kv[key]));
    if (buildDateSet(dates)[today]) { doneToday += 1; }
  }
  return node("section", "habit-overview", {
    title: "總覽",
    children: [
      statCard("habit-stat-total", "習慣數", String(habits.length)),
      statCard("habit-stat-done-today", "今日完成", String(doneToday))
    ]
  });
}

function run(input) {
  if (!input || input.kv === undefined || input.kv === null || typeof input.kv !== "object") {
    return pageDocument("habit-tracker", "習慣追蹤", [
      node("emptyState", "habit-kv-empty", { title: "習慣追蹤需要 storage.kv 能力（尚未提供）" })
    ]);
  }

  var data = input || {};
  var today = data.todayYMD || "";
  var habits = habitsSeed();
  var children = [overviewSection(habits, data.kv, today)];
  for (var i = 0; i < habits.length; i++) {
    children.push(habitSection(habits[i], data.kv, today));
  }
  return pageDocument("habit-tracker", "習慣追蹤", children);
}
