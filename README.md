# flutter_upload

Flutter 桌面工具（Linux），用于打包并部署 maintenance 等项目的 Flutter Web 前端与 Dart 后端。

## 功能

| 按钮 | 说明 |
| --- | --- |
| 上传前端 | 构建 Flutter Web 并通过 FTP 上传到服务器 |
| 上传后端并赋权 | `dart compile exe` 构建后端，FTP 上传二进制与 config.json、远程赋权并重启服务 |
| 部署到移动设备 | 将构建产物部署到移动设备 |
| 打包重命名部署服务器 | 按版本重命名打包产物并部署 |
| 启动后端 / 停止后端 | 本地运行 `dart run bin/server.dart`（工作目录取自设置的「后端本地路径」backendPath），关闭本程序后端继续运行 |
| 楼层管理 | 通过本地 Chrome MCP 复用浏览器登录态，选择校区/楼宇并爬取楼层详情与户型图 |
| ~~VisionRoam 相关~~ | 已迁至 visionroam 仓库的 Flutter Linux 桌面后台（`packages/admin` 运维页）|

## 配置

复制 `ftp_config.example.yaml` 为 `ftp_config.yaml` 并填写真实配置：

```bash
cp ftp_config.example.yaml ftp_config.yaml
```

- `ftp_config.yaml` 含真实密码，已被 `.gitignore` 忽略，请勿提交
- 启动参数可指定配置文件路径：`--config=/path/to/ftp_config.yaml`
- 本地路径支持 `~/` 开头（自动展开为用户主目录）

主要配置项：FTP 主机/端口/账号、前后端本地路径与远程目录、SSH 用户、远程启动命令、
移动端路径；楼层管理的 `floorOutputDir`。
（VisionRoam 相关配置已迁至其桌面后台）

## 楼层管理（Chrome MCP）

点击主界面「楼层管理」，流程：

1. 点击「启动登录 Chrome」，应用会在独立配置目录
   `~/.config/flutter_upload/chrome-profile` 启动 Chrome（调试端口 9222）；
2. 在打开的 Chrome 窗口手动登录房产平台；
3. 点击「加载楼栋」，应用通过 `npx` 启动本地 `chrome-devtools-mcp`，
   连接该 Chrome 并在页面上下文调用接口，加载全部校区/楼栋；
   应用会先等待页面加载完成并验证登录态，单次请求失败最多自动重试 3 次；
4. 在「校区」「楼宇」列表中选择目标楼栋（楼宇支持输入关键字筛选）；
   楼宇列表会按本地 `floors.json` 与图片显示「已完成 / 未完成」，
   楼层列表也会显示每层的获取状态。
   已完成 = 所有楼层详情已获取，且平台存在的户型图已全部下载；
   平台本身没有户型图的楼层会提示「平台无户型图」，但仍按已完成统计。
5. 点击「爬取当前楼栋」，输出目录下保存 `floors.json`、`details/` 与 `images/`；
6. 点击「爬取所有未完成」可依次爬取当前校区所有未完成楼栋，
   期间显示楼栋/楼层进度，可点击「停止批量爬取」在当前楼层结束后停止。

依赖：本机 Chrome 与 Node.js（`npx` 可用）。首次加载会下载
`chrome-devtools-mcp@1.11.0`。登录态保存在专用 Chrome 配置目录中，
过期后重新在 Chrome 里登录即可，无需在应用中填写 Token。

## 远程后端服务管理（systemd）

服务器上的 Dart 后端以 systemd 服务运行，配置文件：
`/etc/systemd/system/dart-backend.service`

```bash
# 修改 service 文件后重新加载
sudo systemctl daemon-reload

# 上传新文件后重启服务
sudo systemctl restart dart-backend

# 查看状态 / 日志
sudo systemctl status dart-backend
sudo journalctl -u dart-backend -f

# 停止 / 启动服务
sudo systemctl stop dart-backend
sudo systemctl start dart-backend
```
