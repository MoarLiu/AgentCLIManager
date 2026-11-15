# 工具标识（assets/tool-logos/）

从各工具的官方网站或官方组织账号下载的原始图标，统一渲染成 128×128 的方形图块。
图标版权归各自厂商，这里仅用于在界面上标识这个工具本身，不作任何背书，也不改变授权。
文件名与 catalog 里的产品 `id` 一致。没有对应文件的用首字母兜底。

取图方式：

- 带不透明底板的原图：满尺寸绘制，底板用自身边缘色补齐成方形。
- 裸字形（SVG / 透明底）：白底 + 16% 内边距，避免黑字形在深色模式下消失。
- CLI 运行时不联网取图，只读本 bundle 内的图。
- 桌面 App 不使用这里的 CLI logo 冒充自己；优先读取本机 `.app` 自带图标，见 `ToolLogo.appIcon`。

| 产品 id | 官方来源 | 主体 |
|---|---|---|
| aider | https://github.com/Aider-AI.png | Aider AI |
| amp | https://ampcode.com/app-icon.png | Sourcegraph |
| auggie | https://www.augmentcode.com/favicon.svg | Augment Code |
| claude-code | https://claude.com/icon.svg | Anthropic |
| cline | https://cline.bot/assets/branding/favicons/apple-touch-icon.png | Cline Bot Inc. |
| codebuddy-code | https://codebuddy-1328495429.cos.accelerate.myqcloud.com/web/ide/logo.svg | Tencent |
| codex | https://github.com/openai.png | OpenAI |
| codexbar | — | Peter Steinberger | **（暂无图，用首字母）**
| continue-cli | https://continue.dev/favicon.png | Continue |
| copilot-cli | https://raw.githubusercontent.com/primer/octicons/main/icons/copilot-24.svg | GitHub（Primer Octicons，MIT） |
| crush | https://github.com/charmbracelet.png | Charmbracelet |
| cursor-cli | https://cursor.com/marketing-static/apple-touch-icon-light.png | Anysphere |
| droid | https://factory.ai/favicon.svg | Factory |
| gemini-cli | https://geminicli.com/icon.png | Google |
| goose | https://raw.githubusercontent.com/block/goose/main/ui/desktop/src/images/icon.png | Block |
| grok-cli | https://grok.com/images/android-chrome-512x512.png | xAI |
| iflow-cli | https://cli.iflow.cn/img/favicon.ico | iFlow AI |
| kilo-cli | https://kilo.ai/favicon/favicon.svg | Kilo Code |
| kimi-code | https://www.kimi.com/pwa-192.png | Moonshot AI |
| kiro-cli | https://kiro.dev/apple-icon.png | Amazon Web Services |
| opencode | https://opencode.ai/apple-touch-icon-v3.png | opencode |
| openhands-cli | https://www.all-hands.dev/favicon.svg | All Hands AI |
| pi | https://pi.dev/favicon.svg | Earendil Works |
| qoder-cli | https://qoder.com（页内 icon，img.alicdn.com 上的 412×412 图） | Qoder |
| qwen-code | https://qwenlm.github.io/qwen-code-docs/favicon.png | Alibaba Cloud (Qwen) |
