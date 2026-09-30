# Validates .claude/memokit.json and emits shell assignments (quoted with @sh).
def err($m): "MK_CONFIG_ERR=\($m | @sh)";
def known: ["$schema","version","project","language","guardedDirs","contextBudget","stateStale","sessionStart","hints","graph"];
def builtin_all: ["debugging","decision","review","handoff","resume","graphify"];
def dir_ok: type == "string"
  and test("^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$")
  and (test("(^|/)\\.\\.?(/|$)") | not)
  and (. != ".git") and (startswith(".git/") | not);
if type != "object" then err("not-object")
elif .version != 1 then err("version")
elif ((.project.name // null) | (type != "string") or (length == 0)) then err("project.name")
elif ((.project.tag // "") | test("^[A-Z][A-Z0-9]{1,9}$") | not) then err("project.tag")
elif ((.language // "en") | IN("tr","en") | not) then err("language")
elif ((.guardedDirs // ["src","tests"]) | (type != "array") or (length == 0) or any(.[]; dir_ok | not)) then err("guardedDirs")
elif ((.contextBudget.limitTokens // 300000) | (type != "number") or (. < 1000)) then err("contextBudget")
elif ((.stateStale.maxCommitsBehind // 3) | (type != "number") or (. < 0)) then err("stateStale")
elif ((.hints.builtin // builtin_all) | (type != "array") or any(.[]; IN(builtin_all[]) | not)) then err("hints")
elif ((.hints.custom // []) | (type != "array") or any(.[]; (.match | type) != "string" or (.text | type) != "string")) then err("hints")
elif has("graph") and ((.graph | type) != "object"
    or ((.graph.root // null) | ((. == ".") or dir_ok) | not)
    or ((.graph.maxCommitsBehind // 20) | (type != "number") or (. < 0))
    or ((.graph | has("refreshScript")) and (.graph.refreshScript | dir_ok | not))) then err("graph")
else
  [ "MK_CONFIG_ERR=''",
    "MK_NAME=\(.project.name | @sh)",
    "MK_TAG=\(.project.tag | @sh)",
    "MK_LANG=\((.language // "en") | @sh)",
    "MK_GUARDED_DIRS=\((.guardedDirs // ["src","tests"]) | join("\n") | @sh)",
    "MK_CONTEXT_LIMIT=\((.contextBudget.limitTokens // 300000) | floor | tostring | @sh)",
    "MK_STATE_MAX_BEHIND=\((.stateStale.maxCommitsBehind // 3) | floor | tostring | @sh)",
    "MK_HEALTH_SCRIPT=\((.sessionStart.healthScript // "") | @sh)",
    "MK_SESSION_DOCS=\((.sessionStart.docs // []) | map(tostring) | join("\n") | @sh)",
    "MK_HINTS_BUILTIN=\((.hints.builtin // builtin_all) | join(" ") | @sh)",
    "MK_HINTS_CUSTOM_JSON=\((.hints.custom // []) | tojson | @sh)",
    "MK_GRAPH_ROOT=\((.graph.root // "") | @sh)",
    "MK_GRAPH_MAX_BEHIND=\((.graph.maxCommitsBehind // 20) | floor | tostring | @sh)",
    "MK_GRAPH_REFRESH_SCRIPT=\((.graph.refreshScript // "") | @sh)",
    "MK_CONFIG_WARN=\([keys[] | select(. as $k | known | index($k) | not)] | join(",") | @sh)"
  ] | join("\n")
end
