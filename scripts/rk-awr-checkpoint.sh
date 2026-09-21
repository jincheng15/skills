#!/usr/bin/env bash
# ==============================================================================
# R&K Flow -> AWR 0.5.0 会话检查点记录辅助工具
# 解决各角色在阶段交接时无法获取 Session ID 与 CAS 锁版本的问题
# 具备多级降级支持：优先 python3，次选 jq，纯 POSIX (awk/sed/grep) 彻底支持 Git Bash
# ==============================================================================
set -euo pipefail

WORK=""
AGENT=""
DIGEST=""
NEXT_ACTION=""
OPEN_LOOP=""
END_SESSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --digest) DIGEST="$2"; shift 2 ;;
    --next-action) NEXT_ACTION="$2"; shift 2 ;;
    --open-loop) OPEN_LOOP="$2"; shift 2 ;;
    --end) END_SESSION=true; shift 1 ;;
    *)
      echo "❌ 错误: 未知参数 '$1'"
      echo "用法: $0 --work <SPEC-ID> --agent <ROLE> --digest \"<本次完成简述>\" [--next-action \"<下一步>\"] [--open-loop \"<未决事项>\"] [--end]"
      exit 1
      ;;
  esac
done

if ! command -v awr >/dev/null 2>&1; then
  echo "⚠️ awr 未安装，跳过会话检查点记录"
  exit 0
fi

if [ -z "$WORK" ] || [ -z "$AGENT" ] || [ -z "$DIGEST" ]; then
  echo "❌ 错误: --work, --agent, --digest 为必填参数"
  echo "用法: $0 --work <SPEC-ID> --agent <ROLE> --digest \"<本次完成简述>\" [--next-action \"<下一步>\"] [--open-loop \"<未决事项>\"] [--end]"
  exit 1
fi

# 向上定位最近的 AWR 项目根目录（包含 .awr/project.toml），支持 monorepo 与深层子目录执行
find_awr_project_root() {
  local d="$PWD"
  while [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -f "$d/.awr/project.toml" ]; then
      printf "%s" "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  # 未找到则返回当前目录，交由后续 awr status 报错
  printf "%s" "$PWD"
}

AWR_ROOT="$(find_awr_project_root)"
cd "$AWR_ROOT"

extract_json_field() {
  local field="$1"
  local input
  input="$(cat)"

  if command -v python3 >/dev/null 2>&1; then
    local py_res
    py_res=$(printf "%s" "$input" | python3 -c "import sys, json
try:
    data = json.load(sys.stdin)
    cur = data
    for part in '$field'.split('.'):
        if not part: continue
        if isinstance(cur, dict): cur = cur.get(part)
        else: cur = None; break
    if cur is not None and not isinstance(cur, (dict, list)):
        print(cur)
except Exception:
    pass" 2>/dev/null || true)
    if [ -n "$py_res" ]; then
      printf "%s" "$py_res"
      return
    fi
  fi

  if command -v jq >/dev/null 2>&1; then
    local jq_res
    jq_res=$(printf "%s" "$input" | jq -r ".$field // empty" 2>/dev/null || true)
    if [ -n "$jq_res" ]; then
      printf "%s" "$jq_res"
      return
    fi
  fi

  case "$field" in
    project_revision)
      printf "%s" "$input" | grep -o '"project_revision":[[:space:]]*[0-9]*' | head -n 1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' || true
      ;;
    "work_context.context_hash"|context_hash)
      # 权威 context_hash 恒为 64 位十六进制字符串，定长匹配避免任何字母子串误判与括号截断陷阱
      val=$(printf "%s" "$input" | awk -F'"' '/"work_context"[[:space:]]*:/ { in_wc = 1 } in_wc && /"context_hash"/ { for (i=1; i<=NF; i++) { if ($i ~ /^[0-9a-fA-F]{64}$/) { print $i; exit } } }' || true)
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | grep -o '"context_hash":[[:space:]]*"[0-9a-fA-F]\{64\}"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      fi
      printf "%s" "$val"
      ;;
    "checkpoint.id"|checkpoint_id)
      val=$(printf "%s" "$input" | grep -o '"checkpoint_id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | awk '/"checkpoint":[[:space:]]*{/ {in_cp=1} in_cp && /"id":[[:space:]]*"01/ {match($0, /01[0-9A-Z]+/); print substr($0, RSTART, RLENGTH); exit}' || true)
      fi
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | grep -o '"id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      fi
      printf "%s" "$val"
      ;;
    "session.id"|session_id)
      val=$(printf "%s" "$input" | grep -o '"session_id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | awk '/"session":[[:space:]]*{/ {in_ss=1} in_ss && /"id":[[:space:]]*"01/ {match($0, /01[0-9A-Z]+/); print substr($0, RSTART, RLENGTH); exit}' || true)
      fi
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | grep -o '"id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      fi
      printf "%s" "$val"
      ;;
    "work.id"|work_id)
      val=$(printf "%s" "$input" | awk '
        /"work":[[:space:]]*{/ { in_w = 1 }
        in_w && /"active_claims":[[:space:]]*\[[[:space:]]*\]/ { in_claims = 0; next }
        in_w && /"active_claims":[[:space:]]*\[/ { in_claims = 1 }
        in_claims && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { in_claims = 0 }
        in_w && !in_claims && /"id":[[:space:]]*"01/ {
          match($0, /01[0-9A-Z]+/); print substr($0, RSTART, RLENGTH); exit
        }
      ' || true)
      if [ -z "$val" ]; then
        val=$(printf "%s" "$input" | grep -o '"work_item_id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true)
      fi
      printf "%s" "$val"
      ;;
    id)
      printf "%s" "$input" | grep -o '"id":[[:space:]]*"01[0-9A-Z]*"' | head -n 1 | awk -F'"' '{print $(NF-1)}' || true
      ;;
  esac
}
# 1. 获取当前 project_revision
STATUS_JSON=$(awr status --json 2>/dev/null || echo "{}")
REV=$(printf "%s" "$STATUS_JSON" | extract_json_field "project_revision")

if [ -z "$REV" ]; then
  echo "❌ 错误: 无法获取 AWR 项目版本号，请确认处于有效 AWR 项目根目录下"
  exit 1
fi

# 2. 获取当前工作项内部 ID 并查找匹配的活动会话（传 --active --limit 100 防分页截断）
WORK_SHOW=$(awr work show "$WORK" --json 2>/dev/null || echo "{}")
WORK_ULID=$(printf "%s" "$WORK_SHOW" | extract_json_field "work.id")

SESSIONS_JSON=$(awr session list --active --limit 100 --json 2>/dev/null || echo "{}")
SESSION_ID=""

if command -v python3 >/dev/null 2>&1; then
  SESSION_ID=$(printf "%s" "$SESSIONS_JSON" | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
    wid = '$WORK_ULID'
    for s in d.get('sessions', []):
        if s.get('agent_id') == '$AGENT' and s.get('status') == 'active':
            swid = s.get('work_item_id')
            if (not wid and not swid) or (wid and swid == wid):
                print(s.get('id', ''))
                break
except Exception:
    pass")
elif command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf "%s" "$SESSIONS_JSON" | jq -r --arg a "$AGENT" --arg wid "$WORK_ULID" '.sessions[]? | select(.agent_id == $a and .status == "active" and (($wid == "" and .work_item_id == null) or ($wid != "" and .work_item_id == $wid))) | .id' | head -n 1)
else
  # 纯 POSIX awk 从 JSON 数组块提取 active 会话
  SESSION_ID=$(printf "%s" "$SESSIONS_JSON" | awk -v agent="$AGENT" -v wid="$WORK_ULID" '
    /"agent_id":[[:space:]]*"/ { in_agent = (index($0, agent) > 0) }
    /"status":[[:space:]]*"active"/ { is_active = 1 }
    /"work_item_id":[[:space:]]*"/ { in_work = (wid == "" || index($0, wid) > 0) }
    /"id":[[:space:]]*"01/ {
      if (match($0, /01[0-9A-Z]+/)) {
        cur_id = substr($0, RSTART, RLENGTH)
      }
    }
    /}/ {
      if (in_agent && is_active && (wid == "" || in_work) && cur_id != "") {
        print cur_id
        exit
      }
      in_agent = 0; is_active = 0; in_work = 0; cur_id = ""
    }
  ')
fi
# 3. 若无可用活动会话，主动启动新会话
if [ -z "$SESSION_ID" ]; then
  START_RES=$(awr session start --work "$WORK" --agent "$AGENT" --provider omp --model default --expected-revision "$REV" --json 2>/dev/null || true)
  SESSION_ID=$(printf "%s" "$START_RES" | extract_json_field "session.id")
  [ -z "$SESSION_ID" ] && SESSION_ID=$(printf "%s" "$START_RES" | extract_json_field "session_id")
  [ -z "$SESSION_ID" ] && SESSION_ID=$(printf "%s" "$START_RES" | extract_json_field "id")
  NEW_REV=$(printf "%s" "$START_RES" | extract_json_field "project_revision")
  [ -n "$NEW_REV" ] && REV="$NEW_REV"
fi

# 4. 显式失败阻断，绝不假兜底
if [ -z "$SESSION_ID" ]; then
  echo "❌ 错误: 无法获取或启动 AWR 会话！"
  echo "可能原因: 工作项 [$WORK] 不存在、已被归档/取消，或目标尚未在 AWR 台账注册。"
  echo "请检查 work-ledger.yaml 是否包含该工作项并执行 awr ready / awr status 校验。"
  exit 1
fi

# 5. 二次刷新 project_revision 防止并发冲突
LATEST_STATUS=$(awr status --json 2>/dev/null || echo "{}")
LATEST_REV=$(printf "%s" "$LATEST_STATUS" | extract_json_field "project_revision")
[ -n "$LATEST_REV" ] && REV="$LATEST_REV"

# 6. 获取上下文哈希（必须传递 --session "$SESSION_ID" 防止多会话报错，且绝不拼接伪 JSON）
COMPILE_ERR_FILE=$(mktemp 2>/dev/null || echo "/tmp/awr-comp-err-$$-${RANDOM:-0}")
COMPILE_OUT=$(awr context compile --work "$WORK" --session "$SESSION_ID" --budget 4000 --json 2>"$COMPILE_ERR_FILE" || true)
CTX_HASH=""
if command -v python3 >/dev/null 2>&1; then
  CTX_HASH=$(printf "%s" "$COMPILE_OUT" | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('work_context', {}).get('context_hash') or '')
except Exception:
    pass" 2>/dev/null || true)
elif command -v jq >/dev/null 2>&1; then
  CTX_HASH=$(printf "%s" "$COMPILE_OUT" | jq -r '.work_context.context_hash // empty' 2>/dev/null || true)
fi

if [ -z "$CTX_HASH" ]; then
  CTX_HASH=$(printf "%s" "$COMPILE_OUT" | extract_json_field "work_context.context_hash")
fi

if [ -z "$CTX_HASH" ]; then
  echo "⚠️ 警告: 未能从 AWR 编译输出中获取权威 context_hash，请检查工作项与会话关联" >&2
  if [ -s "$COMPILE_ERR_FILE" ]; then
    echo "AWR 编译错误详情:" >&2
    cat "$COMPILE_ERR_FILE" >&2
  fi
  CTX_TEXT=$(printf "%s" "$COMPILE_OUT" | extract_json_field "work_context.rendered_context")
  if [ -n "$CTX_TEXT" ]; then
    CTX_HASH=$(printf "%s" "$CTX_TEXT" | sha256sum | awk '{print $1}')
  else
    CTX_HASH=$(printf "%s-%s-%s" "$WORK" "$AGENT" "$REV" | sha256sum | awk '{print $1}')
  fi
fi
rm -f "$COMPILE_ERR_FILE"
# 7. 提交会话检查点
CHECKPOINT_ARGS=(
  --session "$SESSION_ID"
  --work "$WORK"
  --context-hash "$CTX_HASH"
  --digest "$DIGEST"
  --next-action "${NEXT_ACTION:-推进下一步}"
  --expected-revision "$REV"
)

if [ -n "$OPEN_LOOP" ]; then
  CHECKPOINT_ARGS+=(--open-loop "$OPEN_LOOP")
fi
CP_ERR_FILE=""
if command -v mktemp >/dev/null 2>&1; then
  CP_ERR_FILE=$(mktemp)
else
  CP_ERR_FILE="/tmp/awr-cp-err-$$-${RANDOM:-0}"
fi

if ! CP_OUT=$(awr session checkpoint "${CHECKPOINT_ARGS[@]}" --json 2>"$CP_ERR_FILE"); then
  echo "❌ 错误: AWR 会话检查点保存失败！"
  [ -s "$CP_ERR_FILE" ] && cat "$CP_ERR_FILE" >&2
  [ -n "$CP_OUT" ] && echo "$CP_OUT" >&2
  rm -f "$CP_ERR_FILE"
  exit 1
fi
rm -f "$CP_ERR_FILE"
CP_ID=$(printf "%s" "$CP_OUT" | extract_json_field "checkpoint.id")

if [ -z "$CP_ID" ]; then
  echo "❌ 错误: AWR 会话检查点响应未包含有效 checkpoint id！"
  echo "AWR 响应: $CP_OUT" >&2
  exit 1
fi

echo "✅ AWR 会话检查点保存成功: $CP_ID (Session: $SESSION_ID, Rev: $REV)"

# 8. 如果指定了 --end，正常关闭当前会话，避免产生 orphan_session
if [ "$END_SESSION" = true ]; then
  STATUS_END=$(awr status --json 2>/dev/null || echo "{}")
  CURR_REV=$(printf "%s" "$STATUS_END" | extract_json_field "project_revision")
  if ! awr session end --session "$SESSION_ID" --expected-revision "${CURR_REV:-$REV}" --json >/dev/null 2>&1; then
    echo "⚠️ 警告: AWR 会话关闭失败 (Session: $SESSION_ID)，可能版本已冲突或已关闭" >&2
  else
    echo "🔒 已正常关闭 AWR 会话: $SESSION_ID"
  fi
fi
