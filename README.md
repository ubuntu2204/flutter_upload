# flutter_upload
将flutter web和dart 后端打包上传到服务器

/xp/www/api.flutter.gold
sudo nano /etc/systemd/system/dart-backend.service

# 重新加载 systemd 配置
sudo systemctl daemon-reload

# 上传新文件后重启服务
sudo systemctl restart dart-backend

# 查看状态
sudo systemctl status dart-backend

# 查看日志
sudo journalctl -u dart-backend -f

# 停止服务
sudo systemctl stop dart-backend

# 启动服务
sudo systemctl start dart-backend