#!/usr/bin/env bash
#
# fix-ccswitch-node.sh — 一键修复 CC Switch「env: node: No such file or directory」
#
# 解决两类问题：
#   A.「env: node: No such file or directory」——GUI 应用继承 launchd 最小 PATH，
#      找不到 node。修复：① node/npm/npx/openclaw 符号链接到 /usr/local/bin
#                          ② LaunchAgent 持久注入含 /usr/local/bin 的 launchd PATH
#                          ③ CC Switch 加为登录项（晚于 LaunchAgent，保证拿到正确 PATH）
#                          ④ 重启 CC Switch
#   B. 诊断检查提示「重复安装」——本机多个 Node 安装里都装了同名上层 CLI
#      （如 nvm 与各类托管/隔离/Homebrew 运行时并存），CC Switch 扫到即报。
#      修复：⑤ 自动发现所有 Node 安装，保留 detect_node 选出的主版本，
#            把其余安装里与它重复的 claude/codex/gemini/openclaw 精确卸载（不动 node 本体）
#
# 额外装一个 launchd 看门狗（自愈）：每 5 分钟自检 CC Switch 的 PATH，
#   一旦缺 /usr/local/bin（即早于 PATH 注入启动）就自动重启，复发无需手动干预。
#
# 用法：
#   ./fix-ccswitch-node.sh            # 完整修复（含重启 + 安装看门狗）
#   ./fix-ccswitch-node.sh --check    # 只诊断，不改任何东西
#   ./fix-ccswitch-node.sh --no-restart # 修复但不重启（手动重启后生效）
#   ./fix-ccswitch-node.sh --watchdog # 看门狗模式（由 launchd 定时调用，异常才重启）
#   ./fix-ccswitch-node.sh --uninstall-watchdog # 卸载看门狗
# 幂等：重复运行安全。
#
set -uo pipefail

CC_APP="/Applications/CC Switch.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/local.environment.path.plist"
USR_LOCAL_BIN="/usr/local/bin"
TARGET_NODE_BIN=""

log()  { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*"; exit 1; }

CHECK_ONLY=0
NO_RESTART=0
WATCHDOG_MODE=0
UNINSTALL_WATCHDOG=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --watchdog) WATCHDOG_MODE=1 ;;
    --uninstall-watchdog) UNINSTALL_WATCHDOG=1 ;;
    *) err "未知参数: $a（仅支持 --check / --no-restart / --watchdog / --uninstall-watchdog）" ;;
  esac
done
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WATCHDOG_LABEL="com.ccswitch-nodefix.watchdog"
WATCHDOG_PLIST="$HOME/Library/LaunchAgents/$WATCHDOG_LABEL.plist"

# 1. 选 node（优先现有 /usr/local/bin/node 指向的 nvm 版，其次 nvm default）
detect_node() {
  local c t
  # 现有 /usr/local/bin/node 若指向 nvm，直接用它（已验证可用）
  if [ -L /usr/local/bin/node ]; then
    t="$(readlink /usr/local/bin/node)"
    case "$t" in
      *"/.nvm/versions/node/"*) TARGET_NODE_BIN="$(dirname "$t")"; return ;;
    esac
  fi
  # nvm default
  if [ -f "$HOME/.nvm/alias/default" ]; then
    local ver; ver="$(cat "$HOME/.nvm/alias/default" | tr -d '[:space:]')"
    c="$HOME/.nvm/versions/node/$ver/bin"
    if [ -x "$c/node" ]; then TARGET_NODE_BIN="$c"; return; fi
  fi
  # 其他 nvm 版本（排除 workbuddy 托管路径）
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    case "$d" in *"/.workbuddy/"*) continue ;; esac
    [ -x "$d/node" ] && TARGET_NODE_BIN="$d" && return
  done
  # shell node（排除 workbuddy 托管）
  if command -v node >/dev/null 2>&1; then
    c="$(dirname "$(command -v node)")"
    case "$c" in *"/.workbuddy/binaries/"*) ;; *) TARGET_NODE_BIN="$c"; return ;; esac
  fi
  err "找不到 node。请先 nvm install 24.18.0 并 nvm alias default 24.18.0"
}

# 2. 引擎兼容检查（仅告警，不阻断）
check_engine() {
  local v; v="$("$TARGET_NODE_BIN/node" --version 2>/dev/null | sed 's/^v//')"
  [ -n "$v" ] || { warn "无法执行目标 node，跳过引擎检查"; return; }
  if "$TARGET_NODE_BIN/node" -e '
    const [ma,mi,pa]=process.argv[1].split(".").map(Number);
    const ge=(a,b,c)=>ma>a||(ma===a&&(mi>b||(mi===b&&pa>=c)));
    const ok=(ge(22,22,3)&&ma<23)||(ge(24,15,0)&&ma<25)||(ge(25,9,0));
    if(!ok){console.error("node "+process.argv[1]+" 不在 openclaw 支持区间");process.exit(1);}
  ' "$v" 2>/dev/null; then
    log "node $v 满足 openclaw 引擎要求"
  else
    warn "node $v 可能不满足 openclaw 引擎要求（需 >=22.22.3 或 >=24.15.0），继续但建议换 24.18.0"
  fi
}

# 2.5 清理「重复安装」：自动发现本机所有 Node 安装，保留 detect_node 选出的主版本
#     （TARGET_NODE_BIN 所在安装），把其余安装里与它同名的 claude/codex/gemini/
#     openclaw 副本精确卸载（不动 node 本体）。
#     仅当某 CLI 在该安装存在、且主版本也有同名时，才判定为重复，避免误卸独有依赖。
CLI_PKGS=(claude:@anthropic-ai/claude-code codex:@openai/codex gemini:@google/gemini-cli openclaw:openclaw)

# 发现所有 Node 安装根目录（含 bin/node 的祖父目录），每行一个
discover_node_roots() {
  local d
  for d in "$HOME"/.nvm/versions/node/*/; do
    [ -x "${d}bin/node" ] && printf '%s\n' "${d%/}"
  done
  for d in "$HOME"/.workbuddy/binaries/node/versions/*/; do
    [ -x "${d}bin/node" ] && printf '%s\n' "${d%/}"
  done
  for d in /opt/homebrew/Cellar/node/*/ /usr/local/Cellar/node/*/; do
    [ -x "${d}bin/node" ] && printf '%s\n' "${d%/}"
  done
}

clean_dup_clis() {
  local primary_root="${TARGET_NODE_BIN%/*}"   # node 安装根 = bin 的父目录
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ "$root" = "$primary_root" ] && continue   # 保留主版本
    local bin_dir="$root/bin"
    [ -d "$bin_dir" ] || continue
    for entry in "${CLI_PKGS[@]}"; do
      local bin="${entry%%:*}" pkg="${entry##*:}"
      [ -e "$bin_dir/$bin" ] || continue
      # 仅当主版本也有同名命令，才算「重复」，避免误卸独有依赖
      if [ ! -e "$TARGET_NODE_BIN/$bin" ]; then
        warn "$bin 仅存在于 $root（主版本无同名），跳过"
        continue
      fi
      if [ "$CHECK_ONLY" -eq 1 ]; then
        warn "[诊断] 将清理重复: $bin_dir/$bin (包 $pkg)，主版本已有同名"
        continue
      fi
      log "清理重复 CLI: $bin (包 $pkg) @ $root"
      "$root/bin/npm" uninstall -g "$pkg" --prefix "$root" 2>&1 | tail -2
      # 兜底：npm 因包结构异常未删干净时，强制移除残留（pkg 来自固定白名单，路径安全）
      if [ -e "$bin_dir/$bin" ]; then
        warn "$bin 经 npm 未清干净，强制移除残留"
        rm -f "$bin_dir/$bin"
        rm -rf "$root/lib/node_modules/$pkg"
      fi
      [ -e "$bin_dir/$bin" ] && warn "$bin 仍残留，请手动检查 $root" || log "$bin 已清理 ✓"
    done
  done < <(discover_node_roots)
}

# 3. 符号链接（统一风格：全部绝对指向 $TARGET_NODE_BIN/<name>）
make_symlinks() {
  if [ ! -w "$USR_LOCAL_BIN" ]; then
    warn "$USR_LOCAL_BIN 不可写，尝试 sudo chown（可能需要密码）"
    sudo chown -R "$(whoami)" "$USR_LOCAL_BIN" || err "无法写入 $USR_LOCAL_BIN，请手动处理权限"
  fi
  for bin in node npm npx openclaw; do
    if [ -e "$TARGET_NODE_BIN/$bin" ]; then
      ln -sf "$TARGET_NODE_BIN/$bin" "$USR_LOCAL_BIN/$bin"
    fi
  done
  "$USR_LOCAL_BIN/node" --version >/dev/null 2>&1 \
    && log "符号链接就绪: $("$USR_LOCAL_BIN/node" --version) (node/npm/npx/openclaw 均指向 $TARGET_NODE_BIN)" \
    || err "符号链接创建失败"
}

# 4. LaunchAgent
install_launchagent() {
  local nvm_bin="$TARGET_NODE_BIN"
  local path_val="/usr/local/bin:${nvm_bin}:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.environment.path</string>
  <key>ProgramArguments</key><array><string>sh</string><string>-c</string>
  <string>launchctl setenv PATH ${path_val}</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl load "$LAUNCH_AGENT" 2>/dev/null \
    || launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null \
    || true
  launchctl setenv PATH "$path_val"
  log "LaunchAgent 已安装并注入 PATH"
}

# 5. 登录项
add_login_item() {
  if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "CC Switch"; then
    log "CC Switch 已在登录项"
    return
  fi
  osascript -e 'tell application "System Events" to make login item at end with properties {name:"CC Switch", path:"/Applications/CC Switch.app", hidden:false}' \
    && log "已添加 CC Switch 登录项" \
    || warn "添加登录项失败（可手动在系统设置→通用→登录项添加 CC Switch）"
}

# 6. 重启 CC Switch
restart_ccswitch() {
  [ -d "$CC_APP" ] || { warn "未找到 $CC_APP，跳过重启"; return; }
  osascript -e 'quit app "CC Switch"' 2>/dev/null || true
  sleep 2
  pkill -f "MacOS/cc-switch" 2>/dev/null || true
  sleep 1
  open -a "CC Switch"
  sleep 3
  log "CC Switch 已重启"
}

# 7. 验证
verify() {
  local pid; pid="$(pgrep -f 'MacOS/cc-switch' | head -1)"
  [ -n "$pid" ] || { warn "CC Switch 未运行，无法验证（打开后再运行本脚本验证）"; return; }
  local ccpath; ccpath="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^PATH=' | sed 's/^PATH=//')"
  echo "$ccpath" | grep -q "/usr/local/bin" \
    && log "CC Switch PATH 含 /usr/local/bin ✓" \
    || { err "CC Switch PATH 仍不含 /usr/local/bin：$ccpath"; }
  if env PATH="$ccpath" /usr/local/bin/openclaw --version >/dev/null 2>&1; then
    log "openclaw 在 CC Switch 环境可运行 ✓"
  else
    err "openclaw 在 CC Switch 环境仍报错"
  fi
}

# 8. 看门狗（自愈）：清理重复 CLI + 仅当 CC Switch PATH 异常时才重启，否则不动作
watchdog_check() {
  # 先清其他 Node 安装里重新出现的重复 CLI（会随工具更新自动回来）
  clean_dup_clis
  # 确保 launchd PATH 含 /usr/local/bin（即使 PATH LaunchAgent 偶发未生效也兜住）
  local cur; cur="$(launchctl getenv PATH 2>/dev/null)"
  if ! printf '%s' "$cur" | grep -q "/usr/local/bin"; then
    launchctl setenv PATH "/usr/local/bin:${TARGET_NODE_BIN}:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  fi
  local pid; pid="$(pgrep -f 'MacOS/cc-switch' | head -1)"
  [ -n "$pid" ] || { log "[watchdog] CC Switch 未运行，跳过"; exit 0; }
  local ccpath; ccpath="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep '^PATH=' | sed 's/^PATH=//')"
  if printf '%s' "$ccpath" | grep -q "/usr/local/bin"; then
    log "[watchdog] CC Switch PATH 正常，无需处理"
    exit 0
  fi
  warn "[watchdog] CC Switch PATH 异常（缺 /usr/local/bin），自动重启修复"
  restart_ccswitch
  log "[watchdog] 已重启 CC Switch"
}

install_watchdog() {
  cat > "$WATCHDOG_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT_PATH</string><string>--watchdog</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>/tmp/ccswitch-watchdog.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/ccswitch-watchdog.err.log</string>
</dict></plist>
PLIST
  launchctl load "$WATCHDOG_PLIST" 2>/dev/null \
    || launchctl bootstrap "gui/$(id -u)" "$WATCHDOG_PLIST" 2>/dev/null \
    || true
  log "看门狗已安装（每 5 分钟自检，CC Switch PATH 异常时自动重启）"
}

uninstall_watchdog() {
  if [ -f "$WATCHDOG_PLIST" ]; then
    launchctl unload "$WATCHDOG_PLIST" 2>/dev/null \
      || launchctl bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null \
      || true
    rm -f "$WATCHDOG_PLIST"
    log "看门狗已卸载"
  else
    log "看门狗本就未安装"
  fi
}

# ---- main ----
detect_node

if [ "$WATCHDOG_MODE" -eq 1 ]; then
  watchdog_check
  exit 0
fi
if [ "$UNINSTALL_WATCHDOG" -eq 1 ]; then
  uninstall_watchdog
  exit 0
fi

log "目标 node: $TARGET_NODE_BIN ($("$TARGET_NODE_BIN/node" --version))"
check_engine
clean_dup_clis

if [ "$CHECK_ONLY" -eq 1 ]; then
  log "=== 诊断模式（不改任何东西）==="
  [ -x "$USR_LOCAL_BIN/node" ] && log "/usr/local/bin/node OK ($("$USR_LOCAL_BIN/node" --version))" || warn "/usr/local/bin/node 缺失"
  launchctl getenv PATH 2>/dev/null | grep -q "/usr/local/bin" && log "launchd PATH 含 /usr/local/bin" || warn "launchd PATH 不含 /usr/local/bin"
  if [ -f "$WATCHDOG_PLIST" ] && launchctl list 2>/dev/null | grep -q "$WATCHDOG_LABEL"; then
    log "看门狗已安装 ✓（自愈已启用）"
  else
    warn "看门狗未安装（重跑完整修复可启用自愈，复发无需手动干预）"
  fi
  verify
  exit 0
fi

make_symlinks
install_launchagent
add_login_item
install_watchdog
if [ "$NO_RESTART" -eq 0 ]; then
  restart_ccswitch
  verify
else
  log "跳过重启，请手动重启 CC Switch 后运行 --check 验证"
fi
log "全部完成（符号链接 + launchd PATH + 登录项 + 看门狗自愈 + 重复 CLI 清理）。复发时无需手动干预。"
