# Web Launch Console

一个适用于 Windows 的通用网页启动控制台。它使用 PowerShell/WPF 提供图形界面，可以启动静态网站或自定义 Web 命令、管理任意附属服务、执行健康检查，并按需创建 Cloudflare 临时公网地址。

## 功能

- 托管任意 HTML、React、Vue 等构建产物
- 支持单页应用的 `index.html` fallback
- 支持使用自定义命令启动已有 Web Server
- 配置任意数量的 API、AI 或其他附属进程
- 为每个组件执行独立健康检查并显示实时状态
- 精确跟踪和停止本控制台启动的进程树
- 可选访问口令与内置登录页
- 可选 Cloudflare Quick Tunnel
- 统一查看日志、复制或打开访问地址

## 环境要求

- Windows PowerShell 5.1
- Node.js 18 或更高版本
- 如需公网连接：安装 `cloudflared` 并加入 `PATH`

## 快速开始

1. 复制配置模板：

   ```powershell
   Copy-Item controller-config.example.json controller-config.json
   ```

2. 编辑 `controller-config.json`，至少设置 `web.root`。
3. 如果配置了 `environmentFiles`，创建对应文件并写入所需环境变量。
4. 双击 `WebLaunchControlPanel.vbs`。

`controller-config.json`、环境文件和 `runtime/` 均不应提交到版本库。

## 网页模式

静态模式由内置的零依赖 Node.js Server 托管指定目录：

```json
{
  "web": {
    "mode": "static",
    "root": "C:\\sites\\my-app\\dist",
    "port": 8088,
    "spaFallback": true
  }
}
```

如需访问口令，在环境文件中定义变量，并通过 `accessPasswordEnv` 引用变量名。口令不会写入受 Git 跟踪的文件。

已有开发服务器或生产服务器时，可以使用命令模式：

```json
{
  "web": {
    "name": "Frontend",
    "mode": "command",
    "command": "npm.cmd",
    "args": ["run", "preview", "--", "--port", "8088"],
    "workingDirectory": "C:\\sites\\my-app",
    "url": "http://127.0.0.1:8088",
    "healthUrl": "http://127.0.0.1:8088"
  }
}
```

## 附属服务

`services` 是可选数组。每一项支持 `id`、`name`、`command`、`args`、`workingDirectory`、`environmentFiles`、`environment`、`unsetEnvironment`、`healthUrl` 和 `healthTimeoutSeconds`。默认情况下，如果健康地址在启动前已经可访问，控制台会拒绝启动以免接管其他实例；确有需要时可显式设置 `allowExisting`。

顶层 `environmentFiles` 和 `environment` 会应用到网页进程及所有附属服务，组件自己的环境配置具有更高优先级。所有相对路径都以控制台目录为基准。

环境变量值可以使用 `${env:VARIABLE}` 引用现有变量，或使用 `${random:group}` 生成同组进程共享的临时随机密钥。

## 安全提示

- 不要将包含密钥或口令的环境文件提交到 Git。
- 控制台只会停止其 PID 文件中明确记录的进程，不会按模糊名称结束其他程序。
- 停止服务时会清除子进程标准输出和错误日志，控制台自身的生命周期日志仍保留在本机。
- Cloudflare Quick Tunnel 适合临时演示，不提供生产环境可用性保证。
