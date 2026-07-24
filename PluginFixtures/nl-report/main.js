// nl-report — 自然語言報告 plugin(消費 host 的 agent.query broker + export.write)。
//
// 兩段式流程,沿用既有消費型 plugin 的 button→re-run seam:
//   1. 首次 render(input.agentResult 為 undefined/null):依報告類型組一個
//      agent.query button(prompt = builtin ReportGenerator 的 system prompt 語意
//      + 任務摘要),交給 host broker 代呼叫 LLM。
//   2. host 把 broker 回來的 markdown 塞進 input.agentResult 後重跑:把報告
//      渲染成 page,並附一個 export.write button 帶 {filename, mimeType, content}
//      讓使用者手動匯出 .md。
//
// 唯讀:不宣告任何 tasks.* 寫入 capability,不產生任何 task-mutation action。
// plugin 全程不接觸 API key、不連網——LLM 存取一律走 host broker。

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
    page: node("page", "nl-report-root", {
      pageID: "nl-report",
      title: "自然語言報告",
      children: children
    })
  };
}

function trimString(value) {
  return typeof value === "string" ? value.replace(/^\s+|\s+$/g, "") : "";
}

function isYMD(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

// 沿用 builtin ReportGenerator.ReportTemplate.builtIn 的四種類型與 system prompt
// 語意,確保 plugin 產出品質與 builtin 對等。
function reportTemplates() {
  return {
    weekly: {
      name: "週報",
      system: "你是任務週報整理助手。請根據提供的任務資料產出一份條理清楚的 markdown 週報,整理本週進展、已完成事項、待跟進事項與風險提醒。只輸出 markdown,不要前言,不要把整份內容包在程式碼區塊。"
    },
    progress: {
      name: "進度摘要",
      system: "你是進度摘要助手。請根據提供的任務資料產出一份精簡但完整的 markdown 進度摘要,聚焦目前進度、重要里程碑、阻塞點與下一步。只輸出 markdown,不要前言,不要把整份內容包在程式碼區塊。"
    },
    category: {
      name: "分類統計",
      system: "你是任務分類分析助手。請根據提供的任務資料產出一份 markdown 分類統計報表,按任務內容歸納主題或工作類別,摘要各類別的數量、狀態與觀察。只輸出 markdown,不要前言,不要把整份內容包在程式碼區塊。"
    },
    standup: {
      name: "站會日報",
      system: "你是站會日報助手。請根據提供的任務資料產出一份適合晨會或站會使用的 markdown 日報,清楚分成已完成、進行中、下一步與需要協助。只輸出 markdown,不要前言,不要把整份內容包在程式碼區塊。"
    }
  };
}

function resolveType(value) {
  var key = trimString(value).toLowerCase();
  var templates = reportTemplates();
  return templates.hasOwnProperty(key) ? key : "weekly";
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
    return "僅涵蓋前 " + limit + " 筆任務";
  }
  return null;
}

function summarizeTask(task) {
  var parts = [task.title];
  parts.push("到期:" + (task.due || "無"));
  parts.push(task.completed ? "已完成" : "未完成");
  if (task.lists && task.lists.length) { parts.push("清單:" + task.lists.join("、")); }
  if (task.tags && task.tags.length) { parts.push("標籤:" + task.tags.join("、")); }
  return parts.join(" ｜ ");
}

function queryAction(typeKey, tasks, todayYMD) {
  var template = reportTemplates()[typeKey];
  var limited = limitedTasks(tasks);
  var lines = [];
  var i;
  for (i = 0; i < limited.length; i++) {
    lines.push((i + 1) + ". " + summarizeTask(limited[i]));
  }
  var promptLines = [
    template.system,
    "今天日期:" + (trimString(todayYMD) || "未知"),
    "報告類型:" + template.name
  ];
  if (tasks.length > maximumQueryResults()) {
    promptLines.push("注意:任務量超過上限,僅提供前 " + maximumQueryResults() + " 筆,請於報告標示涵蓋範圍。");
  }
  promptLines.push(lines.length ? "任務清單:" : "任務清單:目前沒有任務,請產出一份「本期無任務」的簡短報告。");
  if (lines.length) { promptLines.push(lines.join("\n")); }
  return {
    type: "agentQuery",
    command: "agent.query",
    prompt: promptLines.join("\n"),
    resultSchema: "nl-report.markdown.v1"
  };
}

function requestPage(input, typeKey, tasks) {
  var template = reportTemplates()[typeKey];
  var note = truncationNote(tasks);
  var section = node("section", "nl-report-request", {
    title: template.name + "生成",
    children: [
      node("text", "nl-report-request-help", {
        value: "AI 會依目前任務產生「" + template.name + "」;產生後可匯出為 Markdown 檔。報告為唯讀,不會修改任何任務。"
      }),
      node("statCard", "nl-report-task-count", {
        title: "任務數",
        value: String(limitedTasks(tasks).length)
      })
    ]
  });
  if (note) {
    section.children.push(node("text", "nl-report-request-limit", { value: note }));
  }
  section.children.push(node("button", "nl-report-generate", {
    title: "產生" + template.name,
    action: queryAction(typeKey, tasks, input.todayYMD)
  }));
  return pageDocument([section]);
}

function emptyTaskPage() {
  return pageDocument([
    node("section", "nl-report-empty", {
      title: "自然語言報告",
      children: [
        node("emptyState", "nl-report-empty-state", { title: "目前沒有任務" })
      ]
    })
  ]);
}

function emptyReportPage(typeKey) {
  var template = reportTemplates()[typeKey];
  return pageDocument([
    node("section", "nl-report-empty-result", {
      title: template.name,
      children: [
        node("emptyState", "nl-report-empty-result-state", { title: "本期沒有可呈現的報告內容" })
      ]
    })
  ]);
}

function reportFilename(typeKey, todayYMD) {
  var date = isYMD(trimString(todayYMD)) ? trimString(todayYMD) : "undated";
  return "nl-report-" + typeKey + "-" + date + ".md";
}

function exportAction(typeKey, todayYMD, content) {
  return {
    type: "exportWrite",
    command: "export.write",
    filename: reportFilename(typeKey, todayYMD),
    mimeType: "text/markdown",
    content: content,
    destination: "file"
  };
}

function reportPage(input, typeKey, tasks) {
  var report = trimString(input.agentResult);
  if (!report) { return emptyReportPage(typeKey); }
  var template = reportTemplates()[typeKey];
  var note = truncationNote(tasks);
  var contentChildren = [];
  if (note) {
    contentChildren.push(node("text", "nl-report-content-limit", { value: note }));
  }
  contentChildren.push(node("text", "nl-report-body", { value: report }));
  var children = [
    node("section", "nl-report-content", {
      title: template.name,
      children: contentChildren
    }),
    node("section", "nl-report-actions", {
      title: "匯出",
      children: [
        node("text", "nl-report-export-help", {
          value: "將報告存成 Markdown 檔;匯出由你手動觸發,不會自動落盤。"
        }),
        node("button", "nl-report-export", {
          title: "匯出 Markdown",
          action: exportAction(typeKey, input.todayYMD, report)
        })
      ]
    })
  ];
  return pageDocument(children);
}

function run(input) {
  var safe = input || {};
  var tasks = safe.tasks instanceof Array ? safe.tasks : [];
  var typeKey = resolveType(safe.reportType);
  if (safe.agentResult === undefined || safe.agentResult === null) {
    if (!tasks.length) { return emptyTaskPage(); }
    return requestPage(safe, typeKey, tasks);
  }
  return reportPage(safe, typeKey, tasks);
}
