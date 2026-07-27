const { app, BrowserWindow, Menu, shell } = require('electron');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');

const VIEWER_URL = 'http://127.0.0.1:8799/';
const SERVER_PATH =
  process.env.TEAMS_VIEWER_SERVER ||
  path.resolve(__dirname, '..', 'viewer', 'server.py');
const START_TIMEOUT_MS = 30000;

let win = null;

function probe() {
  return new Promise((resolve) => {
    const request = http.get(VIEWER_URL, (response) => {
      response.resume();
      resolve(true);
    });

    request.setTimeout(1500, () => request.destroy());
    request.on('error', () => resolve(false));
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function ensureServer() {
  if (await probe()) {
    return true;
  }

  try {
    const server = spawn('pythonw.exe', [SERVER_PATH], {
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
    });
    // spawn failures (for example, pythonw.exe missing from PATH) are emitted
    // asynchronously rather than thrown by spawn().
    server.on('error', () => {});
    server.unref();
  } catch {
    return false;
  }

  const attempts = Math.ceil(START_TIMEOUT_MS / 500);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await delay(500);
    if (await probe()) {
      return true;
    }
  }
  return false;
}

async function createWindow() {
  win = new BrowserWindow({
    width: 1280,
    height: 860,
    title: 'Teams Viewer',
    icon: path.join(__dirname, 'assets', 'icon.ico'),
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  Menu.setApplicationMenu(null);
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
  win.on('closed', () => {
    win = null;
  });

  if (await ensureServer()) {
    await win.loadURL(VIEWER_URL);
    return;
  }

  const message = `
    <!doctype html>
    <html lang="ko">
      <meta charset="utf-8">
      <title>Teams Viewer</title>
      <style>
        body { font-family: sans-serif; margin: 48px; line-height: 1.7; color: #333; }
        h1 { color: #5b5fc7; }
      </style>
      <h1>로컬 뷰어 서버에 연결할 수 없습니다.</h1>
      <p>127.0.0.1:8799 서버가 연결되지 않았습니다.</p>
      <p>설치를 다시 실행하거나 작업 스케줄러의 TeamsRecordViewer 상태를 확인해 주세요.</p>
    </html>`;
  await win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(message)}`);
}

const hasLock = app.requestSingleInstanceLock();

if (!hasLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) {
        win.restore();
      }
      win.focus();
    }
  });

  app.whenReady().then(createWindow);

  app.on('window-all-closed', () => {
    app.quit();
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
}
