# Validates .claude/memokit.json and emits shell assignments (quoted with @sh).
def err($m): "MK_CONFIG_ERR=\($m | @sh)";
def known: ["$schema","version","project","language","guardedDirs","contextBudget","stateStale","sessionStart","hints","graph","careful","remote","scratch","disk","parallel","review","convert"];
def builtin_all: ["debugging","decision","review","handoff","resume","graphify","context7"];
def dir_ok: type == "string"
  and test("^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$")
  and (test("(^|/)\\.\\.?(/|$)") | not)
  and (test("(^|/)\\.git(/|$)"; "i") | not);
# A .git segment at any depth, any case, is refused (I8, p21).
# Like dir_ok, but a leading dot is allowed (".claude/...") for remote.runbooksDir / remote.log.
def path_ok: type == "string"
  and test("^[A-Za-z0-9_.-][A-Za-z0-9._-]*(/[A-Za-z0-9_.-][A-Za-z0-9._-]*)*$")
  and (test("(^|/)\\.\\.?(/|$)") | not)
  and (test("(^|/)\\.git(/|$)"; "i") | not);
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
elif has("careful") and ((.careful | type) != "object"
    or ((.careful.patterns // []) | (type != "array") or any(.[];
         (type != "object")
         or ((.match | type) != "string") or ((.match | length) == 0)
         or ((.label | type) != "string") or ((.label | test("^[a-z0-9][a-z0-9-]{0,31}$")) | not)
         or (has("target") and ((.target | type) != "string" or ((.target | test("^[a-z0-9][a-z0-9-]{0,31}$")) | not)))))) then err("careful")
elif has("remote") and ((.remote | type) != "object"
    or ((.remote | keys - ["deployBranches","hosts","readOnlyFirstWords","windowMinutes","runbooksDir","log"]) | length > 0)
    or ((.remote.deployBranches // []) | (type != "array") or any(.[]; (type != "string") or (test("^[A-Za-z0-9._/-]+$") | not)))
    or ((.remote.hosts // []) | (type != "array") or any(.[]; (type != "string") or (test("^\\S+$") | not)))
    or ((.remote.readOnlyFirstWords // []) | (type != "array") or any(.[]; (type != "string") or (test("^[A-Za-z0-9_.+]+(-[A-Za-z0-9_.+]+)?$") | not)))
    # 240: MK_CF_WINDOW_MAX_MIN in careful.sh
    or ((.remote.windowMinutes // 30) | (type != "number") or (. != floor) or (. < 1) or (. > 240))
    or ((.remote.runbooksDir // ".claude/memokit/runbooks") | path_ok | not)
    or ((.remote.log // "docs/DEPLOYS.md") | path_ok | not)) then err("remote")
elif has("scratch") and ((.scratch | type) != "object"
    or ((.scratch.agentMaxMB // 1024) | (type != "number") or (. < 1))
    or ((.scratch.staleAfterHours // 24) | (type != "number") or (. < 1))
    or ((.scratch.reportMinMB // 500) | (type != "number") or (. < 0))) then err("scratch")
elif has("disk") and ((.disk | type) != "object"
    or ((.disk.minFreeGB // 30) | (type != "number") or (. < 0))
    or ((.disk.dropWarnGB // 10) | (type != "number") or (. < 1))) then err("disk")
elif has("parallel") and ((.parallel | type) != "object"
    or ((.parallel.maxCoders // 3) | (type != "number") or (. < 1) or (floor != .))
    or ((.parallel.maxReviewers // 3) | (type != "number") or (. < 1) or (floor != .))
    or ((.parallel.auto // false) | type != "boolean")) then err("parallel")
elif has("review") and ((.review | type) != "object"
    or ((.review.model // "auto") | IN("auto","opus","sonnet") | not)
    or ((.review.validate // "high") | IN("high","always","never") | not)) then err("review")
elif has("convert") and ((.convert | type) != "object"
    or ((.convert | keys - ["markitdown"]) | length > 0)
    or ((.convert.markitdown // false) | type != "boolean")) then err("convert")
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
    "MK_CAREFUL_PATTERNS_JSON=\((.careful.patterns // []) | tojson | @sh)",
    "MK_REMOTE_ENABLED=\(if has("remote") then "1" else "0" end | @sh)",
    "MK_REMOTE_DEPLOY_BRANCHES=\((.remote.deployBranches // []) | join("\n") | @sh)",
    "MK_REMOTE_HOSTS=\((.remote.hosts // []) | join("\n") | @sh)",
    "MK_REMOTE_READONLY=\((.remote.readOnlyFirstWords // []) | join("\n") | @sh)",
    "MK_REMOTE_WINDOW_MIN=\((.remote.windowMinutes // 30) | floor | tostring | @sh)",
    "MK_REMOTE_RUNBOOKS_DIR=\((.remote.runbooksDir // ".claude/memokit/runbooks") | @sh)",
    "MK_REMOTE_LOG=\((.remote.log // "docs/DEPLOYS.md") | @sh)",
    "MK_SCRATCH_AGENT_MAX_MB=\((.scratch.agentMaxMB // 1024) | floor | tostring | @sh)",
    "MK_SCRATCH_STALE_HOURS=\((.scratch.staleAfterHours // 24) | floor | tostring | @sh)",
    "MK_SCRATCH_REPORT_MIN_MB=\((.scratch.reportMinMB // 500) | floor | tostring | @sh)",
    "MK_DISK_MIN_FREE_GB=\((.disk.minFreeGB // 30) | floor | tostring | @sh)",
    "MK_DISK_DROP_WARN_GB=\((.disk.dropWarnGB // 10) | floor | tostring | @sh)",
    "MK_PARALLEL_MAX_CODERS=\((.parallel.maxCoders // 3) | floor | tostring | @sh)",
    "MK_PARALLEL_MAX_REVIEWERS=\((.parallel.maxReviewers // 3) | floor | tostring | @sh)",
    "MK_REVIEW_MODEL=\((.review.model // "auto") | @sh)",
    "MK_CONVERT_MARKITDOWN=\(if (.convert.markitdown // false) then "1" else "0" end | @sh)",
    "MK_CONFIG_WARN=\([keys[] | select(. as $k | known | index($k) | not)] | join(",") | @sh)"
  ] | join("\n")
end
