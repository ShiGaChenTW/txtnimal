function cleanObject(extra) {
  var result = {};
  if (extra) {
    for (var key in extra) {
      if (extra.hasOwnProperty(key) && extra[key] !== undefined && extra[key] !== null) {
        result[key] = extra[key];
      }
    }
  }
  return result;
}

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

function button(id, title, action) {
  return node("button", id, { title: title, action: action });
}

function pageDocument(children) {
  return {
    schemaVersion: 1,
    page: node("page", "export-pack-root", {
      pageID: "export-pack",
      title: "匯出套件",
      children: children
    })
  };
}

function ymdToUTC(ymd) {
  var parts = ymd.split("-");
  return Date.UTC(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
}

function addDays(ymd, days) {
  var date = new Date(ymdToUTC(ymd) + days * 86400000);
  var mm = date.getUTCMonth() + 1;
  var dd = date.getUTCDate();
  return date.getUTCFullYear() + "-" +
    (mm < 10 ? "0" + mm : mm) + "-" +
    (dd < 10 ? "0" + dd : dd);
}

function compactYMD(ymd) {
  return ymd.replace(/-/g, "");
}

function escapeICSText(value) {
  var text = String(value || "");
  text = text.replace(/\\/g, "\\\\");
  text = text.replace(/;/g, "\\;");
  text = text.replace(/,/g, "\\,");
  text = text.replace(/\r\n/g, "\n");
  text = text.replace(/\r/g, "\n");
  text = text.replace(/\n/g, "\\n");
  return text;
}

function categoriesForTask(task) {
  var out = [];
  var i;
  for (i = 0; i < (task.lists || []).length; i++) {
    if (task.lists[i]) { out.push(escapeICSText(task.lists[i])); }
  }
  for (i = 0; i < (task.tags || []).length; i++) {
    if (task.tags[i]) { out.push(escapeICSText(task.tags[i])); }
  }
  return out.join(",");
}

function generateICS(tasks) {
  var lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "CALSCALE:GREGORIAN",
    "PRODID:-//txtnimal//export-pack//EN"
  ];
  var i;
  for (i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    if (!task.due) { continue; }
    lines.push("BEGIN:VEVENT");
    lines.push("UID:" + task.id + "@txtnimal");
    lines.push("SUMMARY:" + escapeICSText(task.title || ""));
    lines.push("DTSTART;VALUE=DATE:" + compactYMD(task.due));
    lines.push("DTEND;VALUE=DATE:" + compactYMD(addDays(task.due, 1)));
    lines.push("STATUS:" + (task.completed ? "COMPLETED" : "CONFIRMED"));
    var categories = categoriesForTask(task);
    if (categories) {
      lines.push("CATEGORIES:" + categories);
    }
    lines.push("END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.join("\r\n");
}

function escapeCSVField(value) {
  var text = value === undefined || value === null ? "" : String(value);
  if (/[",\r\n]/.test(text)) {
    return "\"" + text.replace(/"/g, "\"\"") + "\"";
  }
  return text;
}

function csvRow(fields) {
  var escaped = [];
  var i;
  for (i = 0; i < fields.length; i++) {
    escaped.push(escapeCSVField(fields[i]));
  }
  return escaped.join(",");
}

function generateCSV(tasks) {
  var rows = ["id,title,due,completed,lists,tags"];
  var i;
  for (i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    rows.push(csvRow([
      task.id,
      task.title,
      task.due || "",
      task.completed ? "true" : "false",
      (task.lists || []).join(";"),
      (task.tags || []).join(";")
    ]));
  }
  return rows.join("\r\n");
}

function markdownTaskLine(task) {
  var line = (task.completed ? "- [x] " : "- [ ] ") + (task.title || "");
  var i;
  if (task.due) {
    line += " (due:" + task.due + ")";
  }
  for (i = 0; i < (task.lists || []).length; i++) {
    line += " +" + task.lists[i];
  }
  for (i = 0; i < (task.tags || []).length; i++) {
    line += " @" + task.tags[i];
  }
  return line;
}

function appendMarkdownGroup(lines, title, tasks) {
  var i;
  lines.push("## " + title);
  if (tasks.length === 0) {
    lines.push("(無)");
    return;
  }
  for (i = 0; i < tasks.length; i++) {
    lines.push(markdownTaskLine(tasks[i]));
  }
}

function generateMarkdown(tasks, today) {
  var overdue = [];
  var dueToday = [];
  var upcoming = [];
  var noDue = [];
  var completed = [];
  var i;

  for (i = 0; i < tasks.length; i++) {
    var task = tasks[i];
    if (task.completed) {
      completed.push(task);
    } else if (!task.due) {
      noDue.push(task);
    } else if (task.due < today) {
      overdue.push(task);
    } else if (task.due === today) {
      dueToday.push(task);
    } else {
      upcoming.push(task);
    }
  }

  var groups = [
    { title: "逾期", tasks: overdue },
    { title: "今天", tasks: dueToday },
    { title: "即將", tasks: upcoming },
    { title: "無期限", tasks: noDue },
    { title: "已完成", tasks: completed }
  ];
  var lines = [
    "# 任務匯出",
    "產生時間:" + today + " · 共 " + tasks.length + " 筆",
    ""
  ];

  for (i = 0; i < groups.length; i++) {
    appendMarkdownGroup(lines, groups[i].title, groups[i].tasks);
    if (i !== groups.length - 1) {
      lines.push("");
    }
  }
  return lines.join("\n");
}

function exportAction(filename, mimeType, content, destination) {
  return cleanObject({
    type: "exportWrite",
    command: "export.write",
    filename: filename,
    mimeType: mimeType,
    content: content,
    destination: destination
  });
}

function buildPage(tasks, today) {
  var total = tasks.length;
  var withDueCount = 0;
  var i;
  for (i = 0; i < tasks.length; i++) {
    if (tasks[i].due) { withDueCount += 1; }
  }
  var skippedCount = total - withDueCount;
  var ics = generateICS(tasks);
  var csv = generateCSV(tasks);
  var md = generateMarkdown(tasks, today);

  return pageDocument([
    node("section", "export-pack-summary", {
      title: "匯出摘要",
      children: [
        statCard("export-pack-stat-total", "任務總數", String(total)),
        statCard("export-pack-stat-ics", "可匯出行事曆", String(withDueCount)),
        statCard("export-pack-stat-skipped", "行事曆略過(無期限)", String(skippedCount))
      ]
    }),
    node("section", "export-pack-actions", {
      title: "匯出格式與目的地",
      children: [
        button("export-pack-ics-file", "行事曆存檔(.ics)",
               exportAction("txtnimal.ics", "text/calendar", ics, "file")),
        button("export-pack-ics-share", "行事曆分享(.ics)",
               exportAction("txtnimal.ics", "text/calendar", ics, "share")),
        button("export-pack-csv-file", "試算表存檔(.csv)",
               exportAction("txtnimal.csv", "text/csv", csv, "file")),
        button("export-pack-csv-share", "試算表分享(.csv)",
               exportAction("txtnimal.csv", "text/csv", csv, "share")),
        button("export-pack-md-file", "報告存檔(.md)",
               exportAction("txtnimal.md", "text/markdown", md, "file")),
        button("export-pack-md-share", "報告分享(.md)",
               exportAction("txtnimal.md", "text/markdown", md, "share"))
      ]
    }),
    node("section", "export-pack-destinations", {
      title: "其他目的地",
      children: [
        node("emptyState", "export-pack-dest-note", {
          title: "Slack / Notion 目的地由 host 尚未實作;目前支援存檔與分享"
        })
      ]
    })
  ]);
}

function run(input) {
  var data = input || {};
  var tasks = data.tasks || [];
  var today = data.todayYMD || "";
  return buildPage(tasks, today);
}
