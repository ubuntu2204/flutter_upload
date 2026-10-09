# flutter_upload

桌面端打包上传助手（Flutter Linux 应用），将 Flutter Web 前端、Dart 后端、APK 与 VisionRoam 后端构建产物上传到服务器并重启服务。

## 功能按钮

| 按钮 | 功能 | 实现文件 |
| --- | --- | --- |
| 上传前端 | Flutter Web 构建并 FTP 上传 | `lib/actions/frontend_action.dart` |
| 上传后端并赋权 | `dart compile exe` 后 FTP 上传并 SSH 重启 dart-backend | `lib/actions/backend_action.dart` |
| 部署到移动设备 | Flutter APK 构建并上传 | `lib/actions/mobile_action.dart` |
| 打包重命名部署服务器 | 同步版本号后构建 APK 并上传 | `lib/actions/mobile_rename_action.dart` |
| 启动/停止后端 | 本地启动/停止后端进程调试 | `lib/actions/local_server_action.dart` |
| 部署 VisionRoam 后端 | 编译 `main.server.dart` → scp 上传 → 备份旧版 → 重启服务 → 健康检查 | `lib/actions/visionroam_action.dart` |

## 配置文件

配置文件为项目根目录下的 `ftp_config.yaml`（已被 `.gitignore` 忽略，避免密码入库）：

```bash
cp ftp_config.example.yaml ftp_config.yaml   # 首次使用：从示例复制
nano ftp_config.yaml                          # 填写真实配置
```

- `ftp_config.example.yaml` 仅为模板，所有字段说明见其中注释
- `ftp_config.yaml` 为真实配置，应用启动时自动加载，也可在"设置"页修改后保存
- 常用字段：`host`、`sshUser`（需免密登录）、`visionroamPath`、`visionroamBinDir`、`visionroamService`

## 服务器 43.153.85.24 上的服务管理

### dart-backend（Flutter Upload 后端，/xp/www/api.flutter.gold）

```bash
sudo systemctl daemon-reload                  # 重新加载 systemd 配置
sudo systemctl restart dart-backend           # 上传新文件后重启服务
sudo systemctl status dart-backend            # 查看状态
sudo journalctl -u dart-backend -f            # 查看日志
sudo systemctl stop dart-backend              # 停止服务
sudo systemctl start dart-backend             # 启动服务
```

### visionroam（VisionRoam Jaspr SSR 后端，/xp/www/visionroam.art）

- 部署目标：`/xp/www/visionroam.art/visionroam/visionroam/backend/bin/server`
- web 静态资源：`backend/web`（后端以 `../web` 探测 `css/style.css`）
- 监听端口：`0.0.0.0:8080`，健康检查 `http://127.0.0.1:8080/`

```bash
sudo systemctl restart visionroam.service     # 重启服务
sudo systemctl status visionroam.service      # 查看状态
sudo journalctl -u visionroam.service -f      # 查看日志
```

回滚：`bin/` 下保留部署前自动备份的 `server.bak.时间戳`，覆盖回去后重启服务即可。

## 构建

```bash
flutter build linux --release
# 产物: build/linux/x64/release/bundle/flutter_upload
```
