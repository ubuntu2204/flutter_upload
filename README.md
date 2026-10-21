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
| 楼层管理 | 输入楼栋页面链接与登录 Token，爬取楼层树、楼层详情与户型图，归档到本地目录 |
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
移动端路径；楼层管理的 `authToken` 与 `floorOutputDir`。
（VisionRoam 相关配置已迁至其桌面后台）

## 楼层管理

点击主界面「楼层管理」，粘贴楼栋页面链接后点击「爬取楼层」：

1. 调用 `/api/house-base/personal/visual/building/floor/tree` 获取校区 → 楼栋 → 楼层树；
2. 逐层调用 `/api/house-base/personal/visual/building/floor/{id}?type=byDep` 获取楼层详情；
3. 下载 `/api/base/r/{cadPath}` 户型图（平台实际返回 PNG/JPEG，按文件头保存为对应扩展名）；
4. 输出目录下保存 `floors.json`、`details/` 与 `images/`。

接口需要登录态：在浏览器开发者工具 → Application → Local Storage 中找到
`auth._token.local`，将其完整值（形如 `Bearer eyJ...`）填入 Token 输入框。
Token 与输出目录会在爬取成功后写入 `ftp_config.yaml`。

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
