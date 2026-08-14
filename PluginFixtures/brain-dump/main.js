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
    page: node("page", "brain-dump-root", {
      pageID: "brain-dump",
      title: "腦力傾倒拆解",
      children: children
    })
  };
}

function isISODate(value) {
  if (typeof value !== "string") { return false; }
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  var year, month, day, date;
  if (!match) { return false; }
  year = parseInt(match[1], 10);
  month = parseInt(match[2], 10);
  day = parseInt(match[3], 10);
  date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day;
}

function normalizeDue(value) {
  return isISODate(value) ? value : null;
}

function trimString(value) {
  return typeof value === "string" ? value.replace(/^\s+|\s+$/g, "") : "";
}

function normalizeArray(values, sigil) {
  var result = [];
  var seen = {};
  var i, value;
  if (!(values instanceof Array)) { return result; }
  for (i = 0; i < values.length; i++) {
    value = trimString(values[i]);
    if (!value) { continue; }
    if (sigil && value.charAt(0) === sigil) {
      value = trimString(value.slice(1));
    }
    if (!value || seen[value]) { continue; }
    seen[value] = true;
    result.push(value);
  }
  return result;
}

function buildTaskTitle(draft) {
  var parts = [draft.title];
  var i;
  for (i = 0; i < draft.lists.length; i++) {
    parts.push("+" + draft.lists[i]);
  }
  for (i = 0; i < draft.tags.length; i++) {
    parts.push("@" + draft.tags[i]);
  }
  return parts.join(" ");
}

function parseDrafts(agentResult) {
  var parsed = [];
  var drafts = [];
  var i, item, title, normalized;
  if (!agentResult || typeof agentResult !== "string") { return drafts; }
  try {
    parsed = JSON.parse(agentResult);
  } catch (e) {
    return drafts;
  }
  if (!(parsed instanceof Array)) { return drafts; }
  for (i = 0; i < parsed.length && drafts.length < 100; i++) {
    item = parsed[i] || {};
    title = trimString(item.title);
    if (!title) { continue; }
    normalized = {
      title: title,
      due: normalizeDue(item.due),
      lists: normalizeArray(item.lists, "+"),
      tags: normalizeArray(item.tags, "@")
    };
    drafts.push(normalized);
  }
  return drafts;
}

function queryAction() {
  return {
    type: "agentQuery",
    command: "agent.query",
    prompt: [
      "你是 txtnimal 的任務拆解器。",
      "請把使用者貼上的腦力傾倒文字拆成 JSON 陣列。",
      "每筆物件只可包含 title、due、lists、tags。",
      "title 必須精簡且不可包含 due:、+List、@Tag token。",
      "due 只有在可以明確正規化為 YYYY-MM-DD 時才輸出，否則省略。",
      "lists 與 tags 必須是字串陣列。",
      "只回傳 JSON，不要加上 Markdown 或說明文字。",
      "以下是原文：",
      "{{input}}"
    ].join("\n"),
    resultSchema: "braindump.tasks.v1"
  };
}

function draftSummaryText(draft) {
  var parts = [];
  if (draft.due) { parts.push("到期：" + draft.due); }
  if (draft.lists.length) { parts.push("清單：" + draft.lists.join("、")); }
  if (draft.tags.length) { parts.push("標籤：" + draft.tags.join("、")); }
  return parts.length ? parts.join(" ｜ ") : "無到期日、清單或標籤";
}

function draftSection(draft, index) {
  var action = {
    type: "hostCommand",
    command: "tasks.create",
    title: draft.title
  };
  if (draft.due) { action.due = draft.due; }
  if (draft.lists.length) { action.lists = draft.lists; }
  if (draft.tags.length) { action.tags = draft.tags; }
  return node("section", "brain-draft-" + (index + 1), {
    title: "草稿 " + (index + 1),
    children: [
      node("text", "brain-draft-title-" + (index + 1), { value: draft.title }),
      node("button", "brain-create-" + (index + 1), {
        title: "建立：" + buildTaskTitle(draft),
        action: action
      })
    ]
  });
}

function emptyResultPage() {
  return pageDocument([
    node("section", "brain-results", {
      title: "拆解結果",
      children: [
        node("text", "brain-results-note", {
          value: "解析完成後，建立提議會送進審核清單；在你按下套用前，tasks.txt 不會改動。"
        }),
        node("emptyState", "brain-empty", { title: "沒有可建立的任務" })
      ]
    })
  ]);
}

function inputPage() {
  return pageDocument([
    node("section", "brain-input", {
      title: "貼上原文",
      children: [
        node("text", "brain-input-help", {
          value: "貼上會議筆記、語音轉文字或零碎待辦，系統會先拆成任務草稿，再交給你逐筆審核。"
        }),
        node("form", "brain-form", {
          children: [
            node("textField", "braindump-text", { title: "請貼上要拆解的文字" }),
            node("button", "brain-query", { title: "拆解為任務", action: queryAction() })
          ]
        })
      ]
    })
  ]);
}

function resultPage(agentResult) {
  var drafts = parseDrafts(agentResult);
  var children = [];
  var i;
  if (!drafts.length) { return emptyResultPage(); }
  children.push(node("section", "brain-summary", {
    title: "拆解結果",
    children: [
      node("statCard", "brain-draft-count", { title: "草稿數", value: String(drafts.length) }),
      node("text", "brain-summary-note", {
        value: "以下內容僅供檢視；真正建立前仍會進入審核清單。"
      })
    ]
  }));
  for (i = 0; i < drafts.length; i++) {
    children.push(draftSection(drafts[i], i));
  }
  return pageDocument(children);
}

function run(input) {
  if (!input || !input.agentResult) { return inputPage(); }
  return resultPage(input.agentResult);
}
