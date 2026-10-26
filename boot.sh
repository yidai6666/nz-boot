#!/bin/sh
# 哪吒 v2 面板单容器引导：dashboard v2.5.0 + aurora 前端(容器内 nginx) + cloudflared 隧道 + GitHub 备份自愈
# 环境变量: GH_PAT / GH_USER / ARGO_AUTH / NZ_JWTSECRETKEY / BK_REPO
set -u
D=/dashboard/data
GHAPI=https://api.github.com
BK_REPO=${BK_REPO:-$GH_USER/nezha-boot}
AUTH="Authorization: token ${GH_PAT}"
BK_URL="$GHAPI/repos/$BK_REPO/contents/backup/latest.tgz"

log() { echo "[boot $(date -u +%H:%M:%S)] $*"; }

mkdir -p "$D/tsdb" /opt/nz
export NZ_TSDBDATAPATH="$D/tsdb"

# ---------- 1. 数据恢复 ----------
if [ ! -f "$D/config.yaml" ]; then
  log "本地无配置，尝试从 GitHub 备份恢复"
  if wget -qO /tmp/restore.tgz --header="$AUTH" --header="Accept: application/vnd.github.raw" \
      "$GHAPI/repos/$BK_REPO/contents/backup/latest.tgz" 2>/dev/null && [ -s /tmp/restore.tgz ]; then
    tar xzf /tmp/restore.tgz -C /dashboard && log "恢复完成: $(ls "$D" | tr '\n' ' ')"
  else
    log "无可用备份（首次部署），全新初始化"
  fi
fi

# ---------- 2. dashboard 二进制 ----------
if [ ! -x /opt/nz/dashboard ]; then
  log "下载 dashboard v2.5.0"
  wget -qO /tmp/d.zip https://github.com/nezhahq/nezha/releases/download/v2.5.0/dashboard-linux-amd64.zip \
    && cd /opt/nz && busybox unzip -o /tmp/d.zip >/dev/null 2>&1 \
    && mv -f dashboard-linux-amd64 dashboard && chmod +x dashboard && cd /
fi
[ -x /opt/nz/dashboard ] && log "dashboard ready" || log "!! dashboard 缺失，仅提供前端"

# ---------- 3. cloudflared ----------
if [ ! -x /opt/cfd ]; then
  log "下载 cloudflared"
  wget -qO /opt/cfd https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x /opt/cfd
fi

# ---------- 4. 备份函数 ----------
backup_once() {
  tar czf /tmp/bk.tgz -C /dashboard data 2>/dev/null || { log "打包失败，跳过备份"; return 1; }
  B64=$(base64 /tmp/bk.tgz | tr -d '\n')
  [ -n "$B64" ] || return 1
  SHA=$(wget -qO- --header="$AUTH" "$BK_URL" 2>/dev/null | tr ',' '\n' | grep -m1 '"sha"' | sed 's/.*"sha": *"\([a-f0-9]*\)".*/\1/')
  if [ -n "$SHA" ]; then SHAA=",\"sha\":\"$SHA\""; else SHAA=""; fi
  printf '{"message":"auto backup %s","content":"%s","branch":"main"%s}' \
    "$(date -u +%FT%TZ)" "$B64" "$SHAA" > /tmp/body.json
  grep -q '"sha"' /tmp/body.json || true
  R=$(curl -s -m 90 -X PUT -H "$AUTH" -H "Content-Type: application/json" --data @/tmp/body.json "$BK_URL")
  case "$R" in
    *'"content"'*) log "备份成功 $(wc -c < /tmp/bk.tgz) 字节" ;;
    *) log "备份失败: $(echo "$R" | head -c 160)" ;;
  esac
}

# 后台循环：启动 45s 后首次备份，之后每 10 分钟
( sleep 45; backup_once; while true; do sleep 600; backup_once; done ) &

# ---------- 5. 启动进程 ----------
if [ -f "$D/config.yaml" ] && ! grep -q "data_path" "$D/config.yaml"; then
  printf "tsdb:\n  data_path: %s/tsdb\n" "$D" >> "$D/config.yaml"
  log "已注入 tsdb 配置"
fi
cd /dashboard
log "启动 dashboard :8008"
/opt/nz/dashboard 2>&1 &
sleep 2
log "启动 cloudflared 隧道"
/opt/cfd tunnel --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" 2>&1 &
# ---------- 6. 前端坏状态一键修复入口 /heal ----------
cat > /etc/nginx/heal.html <<'HEALEOF'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>正在修复面板…</title>
<style>body{font:16px/1.7 system-ui,-apple-system,"PingFang SC",sans-serif;background:#0b1020;color:#e6edf3;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}div{text-align:center;max-width:560px;padding:28px}b{color:#7ee787}a{color:#7ee787}</style>
<div><b id=t>正在清理坏的页面状态…</b><p id=s>请稍候，1~3 秒后自动进入管理后台，不需要重新输密码。</p></div>
<script>
(function(){
  var s=document.getElementById('s'),t=document.getElementById('t'),go=0;
  try{ ['mainStore','serverStore','notificationStore','aurora-view'].forEach(function(k){localStorage.removeItem(k)}); }
  catch(e){ t.textContent='清理失败：'+e; s.innerHTML='请手动清除本站点数据后重试。'; return; }
  try{ sessionStorage.clear(); }catch(e){}
  t.textContent='已清理，正在进入后台…';
  setTimeout(function(){ go=1; location.replace('/dashboard/'); },1200);
  setTimeout(function(){ if(!go) s.innerHTML='如果没有自动跳转，<a href="/dashboard/">点这里进入后台</a>。'; },4500);
})();
</script>
</html>
HEALEOF

cat > /docker-entrypoint.d/99-heal.sh <<'EOS'
#!/bin/sh
# 在 nginx 模板渲染后，把 /heal 修复入口挂进 server 块
F=/etc/nginx/conf.d/default.conf
[ -f "$F" ] || exit 0
grep -q 'location = /heal' "$F" && exit 0
cp "$F" /tmp/default.conf.bak
awk '{print} /^[ \t]*server[ \t]*\{/ && !d {print "    location = /heal { default_type text/html; alias /etc/nginx/heal.html; }"; d=1}' "$F" > /tmp/nc.$$ && mv /tmp/nc.$$ "$F"
if nginx -t >/dev/null 2>&1; then
  echo "[heal] /heal 已注入"
else
  echo "[heal] !! 注入失败，已还原"
  cp /tmp/default.conf.bak "$F"
fi
EOS
chmod +x /docker-entrypoint.d/99-heal.sh
log "已准备 /heal 一键修复入口"

log "启动 nginx(前端)"
exec /docker-entrypoint.sh nginx -g "daemon off;"
