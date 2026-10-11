#!/bin/bash
# 酷狗概念版 · 本地扫码登录（双击本文件即可运行）
#
# 作用：本地打开一个二维码页面，用「酷狗概念版」APP 扫码并确认登录，
#       登录成功后自动把 USERINFO（userid + token）写入
#       GitHub 仓库 JohnWJ-co/KGM_Auto-check-in 的 Secret。
#
# 终端用法：bash "/Users/qiangwenjun/Desktop/酷狗概念版-扫码登录.command" --dry-run
# （--dry-run 只登录不写 Secret）
#
# 实现说明：下面 heredoc 里的 Node 代码直接交给 node 执行，因此只需要这一个文件。

# 保证找到 homebrew 安装的 node/npm/git/gh（直接从访达双击时 PATH 可能很干净）
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v node >/dev/null 2>&1; then
  echo "❌ 找不到 node，请先安装 Node.js（https://nodejs.org 或 brew install node）"
  read -n 1 -s -r -p "按任意键关闭…"
  exit 1
fi

exec node --input-type=module - "$@" <<'KGM_LOGIN_EOF'
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const REPO = "JohnWJ-co/KGM_Auto-check-in";
const REPO_URL = `https://github.com/${REPO}.git`;
const WORK_DIR = path.join(os.homedir(), ".kgm-checkin");
const REPO_DIR = path.join(WORK_DIR, "repo");
const MAX_MINUTES = 15; // 二维码页面最多保持多久
const QR_BACKSTOP_MS = 10 * 60 * 1000; // 兜底：超过这个时间强制换二维码

const DRY_RUN = process.argv.includes("--dry-run");

let apiPort = 0;
let webPort = 0;
let apiProcess = null;
let webServer = null;
let state = { key: "", png: null, createdAt: 0, status: "等待扫码…", done: false, error: "" };
const deadline = Date.now() + MAX_MINUTES * 60 * 1000;

const log = (...args) => console.log(...args);

function freePort(start) {
  return new Promise((resolve, reject) => {
    const tryPort = (port) => {
      if (port > start + 50) return reject(new Error("找不到可用端口"));
      const server = net.createServer();
      server.once("error", () => tryPort(port + 1));
      server.once("listening", () => server.close(() => resolve(port)));
      server.listen(port, "127.0.0.1");
    };
    tryPort(start);
  });
}

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], ...options });
}

function ensureRepo() {
  mkdirSync(WORK_DIR, { recursive: true });
  if (!existsSync(path.join(REPO_DIR, ".git"))) {
    log("① 首次运行，下载项目代码到", REPO_DIR);
    run("git", ["clone", "--depth", "1", REPO_URL, REPO_DIR]);
  } else {
    log("① 复用已有代码目录，拉取最新代码");
    try {
      run("git", ["-C", REPO_DIR, "pull", "--ff-only"]);
    } catch {
      log("   （拉取失败，继续使用本地版本）");
    }
  }
  if (!existsSync(path.join(REPO_DIR, "api", "node_modules"))) {
    log("② 安装依赖（npm ci，约 20 秒）");
    run("npm", ["ci", "--no-fund", "--no-audit"], { cwd: path.join(REPO_DIR, "api") });
  } else {
    log("② 依赖已存在，跳过安装");
  }
}

async function startApi() {
  apiProcess = spawn("node", ["app.js"], {
    cwd: path.join(REPO_DIR, "api"),
    env: { ...process.env, PORT: String(apiPort) },
    stdio: ["ignore", "ignore", "pipe"],
  });
  apiProcess.stderr.on("data", (d) => process.stderr.write(`[api] ${d}`));
  const base = `http://127.0.0.1:${apiPort}`;
  for (let i = 0; i < 60; i++) {
    try {
      await fetch(`${base}/`, { method: "HEAD" });
      return base;
    } catch {
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error("内置 API 服务启动超时");
}

async function apiGet(base, endpoint) {
  const res = await fetch(base + endpoint);
  return res.json();
}

async function refreshQr(base) {
  const result = await apiGet(base, `/login/qr/key?timestrap=${Date.now()}`);
  if (result.status !== 1) throw new Error("获取二维码失败：" + JSON.stringify(result));
  state.key = result.data.qrcode;
  state.png = Buffer.from(String(result.data.qrcode_img).split(",").pop(), "base64");
  state.createdAt = Date.now();
  state.status = "等待扫码…";
}

/** 轮询扫码状态：1 未扫描 / 2 未确认 / 4 登录成功 / 0 二维码过期 */
async function pollOnce(base) {
  if (!state.key || state.done) return;
  const res = await apiGet(base, `/login/qr/check?key=${state.key}&timestrap=${Date.now()}`);
  const status = res?.data?.status;
  if (status === 0) {
    state.key = ""; // 已过期：页面下次刷新会自动换新，不会扫到失效的码
    return;
  }
  if (status === 2) state.status = "已扫描，请在手机上点击「确认登录」";
  if (status === 4) {
    state.status = "登录成功，正在写入 GitHub Secret…";
    await handleSuccess(res.data);
  }
}

async function handleSuccess(data) {
  state.done = true;
  const userinfo = JSON.stringify([{ userid: data.userid, token: data.token }]);
  const masked = `${String(data.userid).slice(0, 3)}***${String(data.userid).slice(-2)}`;
  log("\n✅ 登录成功，账号 userid:", masked);

  if (DRY_RUN) {
    log("（--dry-run 模式，不写入 Secret）");
    log("USERINFO =", userinfo);
    state.status = "登录成功（dry-run，未写入 Secret）";
    setTimeout(shutdown, 20000);
    return;
  }

  log(`③ 写入 Secret USERINFO → ${REPO}`);
  try {
    execFileSync("gh", ["secret", "set", "USERINFO", "--repo", REPO], {
      input: userinfo,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    log("   ✅ 写入成功");
  } catch (error) {
    state.error = String(error.stderr || error.message).trim();
    log("   ⚠️ 写入失败，请改用 Actions 的 qrcodeLogin 扫码登录：");
    log("   " + state.error);
    state.status = "登录成功，但自动写入 Secret 失败，请改用 Actions 的 qrcodeLogin";
    return;
  }

  log("④ 触发一次签到，验证部署");
  try {
    run("gh", ["workflow", "run", "main.yml", "--repo", REPO]);
    await new Promise((r) => setTimeout(r, 8000));
    const url = run("gh", [
      "run", "list", "--repo", REPO, "--workflow", "main.yml",
      "--limit", "1", "--json", "url", "--jq", ".[0].url",
    ]).trim();
    log("   已触发，查看结果：", url);
  } catch {
    log("   ⚠️ 触发签到失败（不影响已写入的 Secret）");
  }

  state.status = "登录成功，USERINFO 已写入 GitHub Secret";
  setTimeout(shutdown, 20000);
}

const PAGE = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>酷狗概念版 · 扫码登录</title>
<style>
  body{margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
       font-family:-apple-system,"PingFang SC",sans-serif;background:#111;color:#eee;gap:18px}
  img{width:340px;height:340px;background:#fff;border-radius:12px;padding:12px;box-sizing:border-box}
  .status{font-size:16px;color:#7ee787;text-align:center;padding:0 20px}
  .err{color:#ff7b72}
  .hint{font-size:13px;color:#888;max-width:420px;text-align:center;line-height:1.7}
</style></head>
<body>
  <img id="qr" src="/qr.png" alt="二维码加载中…">
  <div class="status __STATUS_CLASS__" id="status">__STATUS__</div>
  <div class="hint">打开「酷狗概念版」APP → 扫一扫 → 确认登录。<br>二维码会自动更新，不用赶时间。</div>
<script>
  async function tick(){
    try{
      const r = await fetch('/status.json');
      const s = await r.json();
      document.getElementById('status').textContent = s.error ? ('⚠️ ' + s.error) : s.status;
      if(s.error) document.getElementById('status').className = 'status err';
      if(s.done) return;
      document.getElementById('qr').src = '/qr.png?t=' + Date.now();
    }catch(e){}
    setTimeout(tick, 3000);
  }
  tick();
</script></body></html>`;

function startWeb(base) {
  webServer = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    try {
      if (url.pathname === "/qr.png") {
        if (!state.key || Date.now() - state.createdAt > QR_BACKSTOP_MS) await refreshQr(base);
        res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
        return res.end(state.png);
      }
      if (url.pathname === "/status.json") {
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        return res.end(JSON.stringify({ status: state.status, done: state.done, error: state.error }));
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      res.end(PAGE.replace("__STATUS_CLASS__", state.error ? "err" : "").replace("__STATUS__", state.status));
    } catch (error) {
      res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      res.end("出错：" + error.message);
    }
  });
  return new Promise((resolve) => webServer.listen(webPort, "127.0.0.1", () => resolve()));
}

function shutdown() {
  if (apiProcess && !apiProcess.killed) apiProcess.kill();
  if (webServer) webServer.close();
  log("\n完成，可以关闭此窗口。");
  process.exit(0);
}

async function main() {
  log("===== 酷狗概念版 · 扫码登录 =====");
  if (!DRY_RUN) {
    try {
      run("gh", ["auth", "status"], { stdio: ["ignore", "ignore", "pipe"] });
    } catch {
      throw new Error("gh 未登录，请先在终端执行：gh auth login");
    }
  }
  apiPort = await freePort(3911);
  webPort = await freePort(3921);
  ensureRepo();
  const base = await startApi();
  await startWeb(base);
  await refreshQr(base);

  const url = `http://127.0.0.1:${webPort}`;
  log("\n③ 已打开浏览器二维码页面：", url);
  log("   请用「酷狗概念版」APP 扫码，并在手机上点击确认登录");
  log(`   （${MAX_MINUTES} 分钟内有效，二维码会自动换新；Ctrl+C 退出）\n`);
  try {
    run("open", [url]);
  } catch {
    log("（浏览器未能自动打开，请手动访问上面的地址）");
  }

  const timer = setInterval(async () => {
    try {
      await pollOnce(base);
    } catch {
      /* 网络抖动，下一轮重试 */
    }
    if (Date.now() > deadline && !state.done) {
      clearInterval(timer);
      log(`\n⏰ ${MAX_MINUTES} 分钟内未完成登录，请重新双击运行。`);
      shutdown();
    }
  }, 3000);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

main().catch((error) => {
  console.error("\n❌ 出错：", error.message);
  if (apiProcess && !apiProcess.killed) apiProcess.kill();
  process.exit(1);
});
KGM_LOGIN_EOF
