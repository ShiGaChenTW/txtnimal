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
    page: node("page", "importers-root", {
      pageID: "importers",
      title: "匯入",
      children: children
    })
  };
}

function run(input) {
  return pageDocument([
    node("section", "importers-sources", {
      title: "從其他工具匯入",
      children: [
        node("text", "importers-reminders-note", {
          value: "目前已支援從 Apple 提醒事項匯入，按下按鈕後會開啟既有的匯入審核流程。"
        }),
        node("button", "importers-reminders", {
          title: "從 Reminders 匯入",
          action: {
            type: "importRead",
            command: "import.read",
            source: "reminders"
          }
        }),
        node("text", "importers-future-oauth", {
          value: "Todoist、TickTick、Google Tasks 仍在規劃中，這些來源需要 OAuth 授權，現在尚未開放。"
        })
      ]
    })
  ]);
}
