module.exports = {
  apps: [{
    name: 'teams-record-remote',
    cwd: '/home/lisyoen/projects/teams-record',
    script: 'remote_web/server.py',
    interpreter: 'python3',
    args: 'serve --config /home/lisyoen/.config/teams-record-remote/config.json',
    autorestart: true,
    max_memory_restart: '512M',
    out_file: '/home/lisyoen/.local/state/teams-record-remote/service.log',
    error_file: '/home/lisyoen/.local/state/teams-record-remote/error.log',
    merge_logs: true,
    time: true,
  }],
};

