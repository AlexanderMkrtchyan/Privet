module.exports = {
  apps: [
    {
      name: 'privet',
      cwd: '/home/alex/Privet/server',
      script: 'src/index.js',
      interpreter: '/root/.nvm/versions/node/v26.2.0/bin/node',
      instances: 1,
      exec_mode: 'fork',
      env: {
        NODE_ENV: 'production',
        PORT: '7777',
        // Only nginx on this host should reach Privet (HTTPS terminates at nginx).
        HOST: '127.0.0.1',
        JWT_SECRET: 'privet-prod-change-me',
        PRIVET_DB_PATH: 'data/privet.sqlite',
        PATH: '/root/.nvm/versions/node/v26.2.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      },
    },
  ],
};
