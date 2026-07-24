function node(type, id, extra) {
  var result = { type: type, id: id };
  var key;
  if (extra) {
    for (key in extra) {
      if (extra.hasOwnProperty(key) && extra[key] !== undefined && extra[key] !== null) {
        result[key] = extra[key];
      }
    }
  }
  return result;
}

function pageDocument(children) {
  return {
    schemaVersion: 1,
    page: node("page", "smart-triage-root", {
      pageID: "smart-triage",
      title: "智慧分流",
      children: children
    })
  };
}

function trimString(value) {
  return typeof value === "string" ? value.replace(/^\s+|\s+$/g, "") : "";
}

function normalizeDue(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
}

function normalizeRank(value) {
  var rank;
  if (typeof value === "number" && isFinite(value)) {
    rank = Math.round(value);
  } else if (typeof value === "string" && trimString(value)) {
    rank = parseInt(trimString(value), 10);
  } else {
    return null;
  }
  return rank > 0 ? rank : null;
}

function normalizeBucket(value) {
  var bucket = trimString(value).toLowerCase();
  return bucket || null;
}

function localTaskLine(task, reason, rank) {
  var parts = [];
  if (rank !== null) { parts.push("#" + rank); }
  parts.push(task.title);
  parts.push("到期：" + (task.due || "無"));
  if (reason) { parts.push("理由：" + reason); }
  return parts.join(" ｜ ");
}

function summarizeTask(task) {
  var parts = [task.id + "｜" + task.title];
  if (task.due) { parts.push("到期 " + task.due); }
  if (task.lists && task.lists.length) { parts.push("清單 " + task.lists.join("、")); }
  if (task.tags && task.tags.length) { parts.push("標籤 " + task.tags.join("、")); }
  if (task.completed) { parts.push("已完成"); }
  return parts.join(" ｜ ");
}

function maximumQueryResults() {
  return 100;
}

function limitedTasks(tasks) {
  var limit = maximumQueryResults();
  return tasks.length > limit ? tasks.slice(0, limit) : tasks.slice(0);
}

function truncationNote(tasks) {
  var limit = maximumQueryResults();
  if (tasks.length > limit) {
    return "僅就前 " + limit + " 筆排序";
  }
  return null;
}

function queryAction(tasks, todayYMD) {
  var limited = limitedTasks(tasks);
  var lines = [];
  var i;
  for (i = 0; i < limited.length; i++) {
    lines.push((i + 1) + ". " + summarizeTask(limited[i]));
  }
  return {
    type: "agentQuery",
    command: "agent.query",
    prompt: [
      "你是 txtnimal 的任務優先級分流助手。",
      "今天日期：" + (trimString(todayYMD) || "未知"),
      "請根據以下任務清單，輸出 JSON 排序結果。",
      "回傳格式優先為陣列，每筆物件包含 taskID、rank、reason，可選 bucket。",
      "bucket 只在你認為現在就該做時填 now，其餘可省略。",
      "rank 從 1 開始且不可重複；若無法判斷可省略該筆 rank。",
      "不要改寫 taskID，不要輸出 Markdown，不要附帶說明文字。",
      "任務清單：",
      lines.join("\n")
    ].join("\n"),
    resultSchema: "triage.ranking.v1"
  };
}

function requestPage(input, tasks) {
  var children = [];
  var note = truncationNote(tasks);
  children.push(node("section", "smart-triage-request", {
    title: "開始分流",
    children: [
      node("text", "smart-triage-request-help", {
        value: "AI 會根據目前任務提出唯讀排序建議；建議不會自動套用到 tasks.txt。"
      }),
      node("statCard", "smart-triage-task-count", {
        title: "任務數",
        value: String(limitedTasks(tasks).length)
      })
    ]
  }));
  if (note) {
    children[0].children.push(node("text", "smart-triage-request-limit", { value: note }));
  }
  children[0].children.push(node("button", "smart-triage-query", {
    title: "請 AI 排序",
    action: queryAction(tasks, input.todayYMD)
  }));
  return pageDocument(children);
}

function emptyTaskPage() {
  return pageDocument([
    node("section", "smart-triage-empty-tasks", {
      title: "智慧分流",
      children: [
        node("emptyState", "smart-triage-empty-state", { title: "目前沒有任務" })
      ]
    })
  ]);
}

function invalidResultPage(tasks) {
  var note = truncationNote(tasks);
  var children = [
    node("section", "smart-triage-invalid", {
      title: "排序結果",
      children: [
        node("text", "smart-triage-invalid-note", {
          value: "AI 結果無法解析，本頁不會套用任何變更。"
        }),
        node("emptyState", "smart-triage-invalid-empty", { title: "沒有可顯示的排序結果" })
      ]
    })
  ];
  if (note) {
    children[0].children.splice(1, 0, node("text", "smart-triage-invalid-limit", { value: note }));
  }
  return pageDocument(children);
}

function unwrapRanking(parsed) {
  if (parsed instanceof Array) { return parsed; }
  if (parsed && parsed.ranking instanceof Array) { return parsed.ranking; }
  if (parsed && parsed.tasks instanceof Array) { return parsed.tasks; }
  return [];
}

function parseRanking(agentResult, taskMap) {
  var parsed;
  var items;
  var ranked = [];
  var seen = {};
  var i, item, taskID, localTask, rank, reason, bucket;
  if (typeof agentResult !== "string" || !trimString(agentResult)) { return ranked; }
  try {
    parsed = JSON.parse(agentResult);
  } catch (e) {
    return ranked;
  }
  items = unwrapRanking(parsed);
  if (!(items instanceof Array)) { return ranked; }
  for (i = 0; i < items.length; i++) {
    item = items[i] || {};
    taskID = trimString(item.taskID);
    if (!taskID || seen[taskID] || !taskMap.hasOwnProperty(taskID)) { continue; }
    localTask = taskMap[taskID];
    rank = normalizeRank(item.rank);
    if (rank === null) { continue; }
    reason = trimString(item.reason) || null;
    bucket = normalizeBucket(item.bucket);
    ranked.push({
      taskID: taskID,
      rank: rank,
      reason: reason,
      bucket: bucket,
      task: localTask
    });
    seen[taskID] = true;
  }
  ranked.sort(function (left, right) {
    if (left.rank !== right.rank) { return left.rank - right.rank; }
    return left.taskID < right.taskID ? -1 : (left.taskID > right.taskID ? 1 : 0);
  });
  return ranked;
}

function focusItems(ranked) {
  var nowItems = [];
  var i;
  for (i = 0; i < ranked.length; i++) {
    if (ranked[i].bucket === "now") {
      nowItems.push(ranked[i]);
    }
  }
  if (nowItems.length) { return nowItems; }
  return ranked.slice(0, 3);
}

function unrankedTasks(tasks, ranked) {
  var rankedIDs = {};
  var result = [];
  var i;
  for (i = 0; i < ranked.length; i++) {
    rankedIDs[ranked[i].taskID] = true;
  }
  for (i = 0; i < tasks.length; i++) {
    if (!rankedIDs[tasks[i].id]) {
      result.push(tasks[i]);
    }
  }
  return result;
}

function summarySection(tasks, ranked, focus) {
  return node("section", "smart-triage-summary", {
    title: "分流統計",
    children: [
      node("statCard", "smart-triage-stat-total", {
        title: "送審任務",
        value: String(tasks.length)
      }),
      node("statCard", "smart-triage-stat-ranked", {
        title: "已排序",
        value: String(ranked.length)
      }),
      node("statCard", "smart-triage-stat-focus", {
        title: "現在該做",
        value: String(focus.length)
      }),
      node("statCard", "smart-triage-stat-unranked", {
        title: "未排序",
        value: String(tasks.length - ranked.length)
      }),
      node("text", "smart-triage-summary-note", {
        value: "以下為唯讀建議頁；排序與理由僅供參考，不會自動修改任務。"
      })
    ]
  });
}

function focusSection(items) {
  var children = [];
  var i;
  if (!items.length) {
    children.push(node("emptyState", "smart-triage-focus-empty", { title: "目前沒有焦點建議" }));
  } else {
    for (i = 0; i < items.length; i++) {
      children.push(node("text", "smart-triage-focus-item-" + (i + 1), {
        value: localTaskLine(items[i].task, items[i].reason, items[i].rank)
      }));
    }
  }
  return node("section", "smart-triage-focus", {
    title: "現在該做",
    children: children
  });
}

function fullOrderSection(ranked) {
  var children = [];
  var i;
  if (!ranked.length) {
    children.push(node("emptyState", "smart-triage-ranked-empty", { title: "沒有可顯示的排序結果" }));
  } else {
    for (i = 0; i < ranked.length; i++) {
      children.push(node("text", "smart-triage-ranked-item-" + (i + 1), {
        value: localTaskLine(ranked[i].task, ranked[i].reason, ranked[i].rank)
      }));
    }
  }
  return node("section", "smart-triage-ranked", {
    title: "完整優先序",
    children: children
  });
}

function unrankedSection(tasks) {
  var children = [];
  var i;
  if (!tasks.length) {
    children.push(node("emptyState", "smart-triage-unranked-empty", { title: "全部任務都已排序" }));
  } else {
    for (i = 0; i < tasks.length; i++) {
      children.push(node("text", "smart-triage-unranked-item-" + (i + 1), {
        value: tasks[i].title + " ｜ 到期：" + (tasks[i].due || "無")
      }));
    }
  }
  return node("section", "smart-triage-unranked", {
    title: "未排序",
    children: children
  });
}

function rankingPage(input) {
  var tasks = limitedTasks(input.tasks || []);
  var taskMap = {};
  var ranked;
  var focus;
  var unranked;
  var children = [];
  var note;
  var i;
  for (i = 0; i < tasks.length; i++) {
    taskMap[tasks[i].id] = {
      id: tasks[i].id,
      title: tasks[i].title,
      due: normalizeDue(tasks[i].due)
    };
  }
  ranked = parseRanking(input.agentResult, taskMap);
  if (!ranked.length) { return invalidResultPage(input.tasks || []); }
  focus = focusItems(ranked);
  unranked = unrankedTasks(tasks, ranked);
  note = truncationNote(input.tasks || []);
  children.push(summarySection(tasks, ranked, focus));
  if (note) {
    children.push(node("text", "smart-triage-result-limit", { value: note }));
  }
  children.push(focusSection(focus));
  children.push(fullOrderSection(ranked));
  children.push(unrankedSection(unranked));
  return pageDocument(children);
}

function run(input) {
  var tasks = (input && input.tasks instanceof Array) ? input.tasks : [];
  if (!tasks.length) { return emptyTaskPage(); }
  if (!input || input.agentResult === undefined || input.agentResult === null) {
    return requestPage(input || {}, tasks);
  }
  return rankingPage(input);
}
