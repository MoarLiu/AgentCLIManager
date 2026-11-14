// 由 scripts/embed-catalog.sh 生成，请勿手工编辑。
// 源文件：catalog/10-local.json, catalog/20-researched.json
enum BuiltinCatalogData {
    static let jsonParts: [String] = [
        #"""
{
  "schemaVersion": 1,
  "products": [
    {
      "id": "claude-code",
      "name": "Claude Code",
      "vendor": "Anthropic",
      "homepage": "https://claude.com/product/claude-code",
      "docs": "https://code.claude.com/docs/en/setup",
      "kind": "cli",
      "binaries": [
        "claude"
      ],
      "packages": [
        "@anthropic-ai/claude-code"
      ],
      "companionApps": [
        "com.anthropic.claudefordesktop"
      ],
      "codeIdentifiers": [
        "com.anthropic.claude-code"
      ],
      "paths": [
        {
          "path": "~/.local/share/claude",
          "kind": "program",
          "exclusive": true
        },
        {
          "path": "~/.local/state/claude",
          "kind": "data"
        },
        {
          "path": "~/Library/Caches/claude-cli-nodejs",
          "kind": "cache"
        },
        {
          "path": "~/.claude",
          "kind": "data",
          "shared": true,
          "note": "官方文档写明：VS Code 扩展、JetBrains 插件和桌面版也写这个位置"
        },
        {
          "path": "~/.claude.json",
          "kind": "config",
          "shared": true,
          "note": "官方文档写明：VS Code 扩展、JetBrains 插件和桌面版也写这个位置"
        },
        {
          "path": "~/.claude.json.backup",
          "kind": "config",
          "shared": true,
          "note": "官方文档写明：VS Code 扩展、JetBrains 插件和桌面版也写这个位置"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://claude.ai/install.sh | bash"
        },
        {
          "channel": "brew",
          "command": "brew install --cask claude-code"
        },
        {
          "channel": "npm",
          "command": "npm install -g @anthropic-ai/claude-code"
        }
      ]
    },
    {
      "id": "codex",
      "name": "Codex CLI",
      "vendor": "OpenAI",
      "homepage": "https://github.com/openai/codex",
      "docs": "https://github.com/openai/codex",
      "kind": "cli",
      "binaries": [
        "codex"
      ],
      "packages": [
        "@openai/codex"
      ],
      "companionApps": [
        "com.openai.codex"
      ],
      "paths": [
        {
          "path": "~/.codex",
          "kind": "data",
          "shared": true,
          "note": "本机实测：ChatGPT.app（bundle id com.openai.codex）也在写这个目录"
        },
        {
          "path": "~/.cache/codex-runtimes",
          "kind": "cache",
          "shared": true
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        },
        {
          "channel": "brew",
          "command": "brew install --cask codex"
        },
        {
          "channel": "npm",
          "command": "npm install -g @openai/codex"
        }
      ]
    },
    {
      "id": "grok-cli",
      "name": "Grok CLI",
      "vendor": "xAI",
      "kind": "cli",
      "binaries": [
        "grok"
      ],
      "codeIdentifiers": [
        "xai-grok-pager"
      ],
      "paths": [
        {
          "path": "~/.grok/downloads",
          "kind": "program"
        },
        {
          "path": "~/.grok/bin",
          "kind": "program"
        },
        {
          "path": "~/.grok/completions",
          "kind": "program"
        },
        {
          "path": "~/.grok/bundled",
          "kind": "program"
        },
        {
          "path": "~/.grok/docs",
          "kind": "program"
        },
        {
          "path": "~/.grok/logs",
          "kind": "logs"
        },
        {
          "path": "~/.grok/auth.json",
          "kind": "credentials"
        },
        {
          "path": "~/.grok",
          "kind": "data",
          "note": "会话、记忆、配置与插件"
        }
      ],
      "note": "条目来自本机实测的目录结构；安装命令未核实，故不提供。"
    },
    {
      "id": "qoder-cli",
      "name": "Qoder CLI",
      "vendor": "Qoder",
      "kind": "cli",
      "binaries": [
        "qodercli",
        "qoder"
      ],
      "companionApps": [
        "com.qoder.app",
        "com.qodercn.app"
      ],
      "codeIdentifiers": [
        "qodercli"
      ],
      "paths": [
        {
          "path": "~/.qoder/bin/qodercli",
          "kind": "program",
          "note": "各版本的 qodercli 二进制，旧版本可展开后单独清理"
        },
        {
          "path": "~/.qoder/entry",
          "kind": "program",
          "shared": true,
          "note": "qoder 分发脚本，同时负责启动 Qoder 桌面版"
        },
        {
          "path": "~/.qoder/.auth",
          "kind": "credentials",
          "shared": true
        },
        {
          "path": "~/.qoder",
          "kind": "data",
          "shared": true
        }
      ],
      "note": "条目来自本机实测的目录结构；安装命令未核实，故不提供。"
    },
    {
      "id": "pi",
      "name": "pi",
      "vendor": "Earendil Works",
      "kind": "cli",
      "binaries": [
        "pi"
      ],
      "packages": [
        "@earendil-works/pi-coding-agent"
      ],
      "companionApps": [
        "com.pi-gui.desktop"
      ],
      "versionFile": "~/.pi/agent/install/current-version",
      "paths": [
        {
          "path": "~/.pi/agent/install",
          "kind": "program"
        },
        {
          "path": "~/.pi/agent/bin",
          "kind": "program"
        },
        {
          "path": "~/.pi/agent/auth.json",
          "kind": "credentials"
        },
        {
          "path": "~/.pi/agent/mcp.json",
          "kind": "credentials",
          "note": "MCP 服务配置，env 段里存有 API key"
        },
        {
          "path": "~/.pi",
          "kind": "data",
          "shared": true
        }
      ],
      "note": "条目来自本机实测的目录结构；安装命令未核实，故不提供。"
    },
    {
      "id": "cursor-cli",
      "name": "Cursor CLI",
      "vendor": "Anysphere",
      "homepage": "https://cursor.com/cli",
      "docs": "https://cursor.com/docs/cli/installation",
      "kind": "cli",
      "binaries": [
        "cursor-agent",
        "agent"
      ],
      "companionApps": [
        "com.todesktop.230313mzl4w4u92"
      ],
      "paths": [
        {
          "path": "~/.cursor",
          "kind": "data",
          "shared": true,
          "note": "Cursor 编辑器与 Cursor CLI 共用"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl https://cursor.com/install -fsS | bash"
        }
      ],
      "note": "官方文档里安装后验证用的是 agent --version；cursor-agent 是它的旧名字。目录清单里两个都收，按签名身份优先匹配。"
    },
    {
      "id": "codexbar",
      "name": "CodexBar",
      "vendor": "Peter Steinberger",
      "kind": "app",
      "bundleIDs": [
        "com.steipete.codexbar"
      ],
      "paths": [
        {
          "path": "~/.codexbar",
          "kind": "data",
          "exclusive": true
        },
        {
          "path": "~/.config/codexbar",
          "kind": "config",
          "exclusive": true
        }
      ]
    }
  ]
}
"""#,
        #"""
{
  "schemaVersion": 1,
  "products": [
    {
      "id": "gemini-cli",
      "name": "Gemini CLI",
      "vendor": "Google",
      "homepage": "https://github.com/google-gemini/gemini-cli",
      "kind": "cli",
      "binaries": [
        "gemini"
      ],
      "packages": [
        "@google/gemini-cli",
        "gemini-cli"
      ],
      "paths": [
        {
          "path": "~/.gemini",
          "kind": "data"
        },
        {
          "path": "~/.gemini/bin",
          "kind": "program"
        },
        {
          "path": "~/.gemini/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.gemini/GEMINI.md",
          "kind": "data"
        },
        {
          "path": "~/.gemini/tmp",
          "kind": "data"
        },
        {
          "path": "~/.gemini/installation_id",
          "kind": "data"
        },
        {
          "path": "~/.gemini/oauth_creds.json",
          "kind": "credentials"
        },
        {
          "path": "~/.gemini/google_accounts.json",
          "kind": "credentials"
        },
        {
          "path": "~/.gemini/mcp-oauth-tokens.json",
          "kind": "credentials"
        },
        {
          "path": "~/.gemini/a2a-oauth-tokens.json",
          "kind": "credentials"
        }
      ],
      "install": [
        {
          "channel": "npm",
          "command": "npm install -g @google/gemini-cli"
        },
        {
          "channel": "brew",
          "command": "brew install gemini-cli"
        },
        {
          "channel": "other",
          "command": "sudo port install gemini-cli"
        }
      ],
      "uninstallCommand": "npm uninstall -g @google/gemini-cli",
      "docs": "https://geminicli.com/docs/resources/uninstall"
    },
    {
      "id": "opencode",
      "name": "opencode",
      "homepage": "https://opencode.ai",
      "kind": "cli",
      "binaries": [
        "opencode",
        "opencode2"
      ],
      "packages": [
        "@opencode/cli",
        "opencode-ai",
        "opencode",
        "anomalyco/tap/opencode-v2",
        "anomalyco/tap/opencode"
      ],
      "companionApps": [
        "ai.opencode.desktop"
      ],
      "paths": [
        {
          "path": "~/.opencode/bin",
          "kind": "program"
        },
        {
          "path": "~/.config/opencode",
          "kind": "config"
        },
        {
          "path": "~/.local/share/opencode",
          "kind": "data"
        },
        {
          "path": "~/.local/share/opencode/opencode.db",
          "kind": "data"
        },
        {
          "path": "~/.local/share/opencode/auth.json",
          "kind": "credentials"
        },
        {
          "path": "~/.local/share/opencode/log",
          "kind": "logs"
        },
        {
          "path": "~/.local/state/opencode",
          "kind": "data"
        },
        {
          "path": "~/.cache/opencode",
          "kind": "cache"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://opencode.ai/v2/install | bash"
        },
        {
          "channel": "npm",
          "command": "npm i -g @opencode/cli@latest"
        },
        {
          "channel": "brew",
          "command": "brew install anomalyco/tap/opencode-v2"
        },
        {
          "channel": "brew",
          "command": "brew install opencode"
        }
      ],
      "uninstallCommand": "opencode uninstall",
      "docs": "https://opencode.ai/docs/cli/"
    },
    {
      "id": "aider",
      "name": "Aider",
      "vendor": "Aider AI",
      "homepage": "https://aider.chat",
      "kind": "cli",
      "binaries": [
        "aider"
      ],
      "packages": [
        "aider-chat",
        "aider-install"
      ],
      "paths": [
        {
          "path": "~/.aider",
          "kind": "data"
        },
        {
          "path": "~/.aider/caches",
          "kind": "cache"
        },
        {
          "path": "~/.aider/analytics.json",
          "kind": "data"
        },
        {
          "path": "~/.aider/installs.json",
          "kind": "data"
        },
        {
          "path": "~/.aider/oauth-keys.env",
          "kind": "credentials"
        },
        {
          "path": "~/.aider.conf.yml",
          "kind": "config"
        },
        {
          "path": "~/.aider.model.settings.yml",
          "kind": "config"
        },
        {
          "path": "~/.aider.model.metadata.json",
          "kind": "config"
        }
      ],
      "install": [
        {
          "channel": "other",
          "command": "python -m pip install aider-install && aider-install"
        },
        {
          "channel": "script",
          "command": "curl -LsSf https://aider.chat/install.sh | sh"
        },
        {
          "channel": "uv",
          "command": "uv tool install --force --python python3.12 --with pip aider-chat@latest"
        },
        {
          "channel": "pipx",
          "command": "pipx install aider-chat"
        }
      ],
      "docs": "https://aider.chat/docs/install.html"
    },
    {
      "id": "goose",
      "name": "Goose",
      "vendor": "Block",
      "homepage": "https://goose-docs.ai",
      "kind": "cli",
      "binaries": [
        "goose"
      ],
      "packages": [
        "block-goose-cli",
        "block-goose"
      ],
      "paths": [
        {
          "path": "~/.config/goose",
          "kind": "config"
        },
        {
          "path": "~/.config/goose/config.yaml",
          "kind": "config"
        },
        {
          "path": "~/.config/goose/history.txt",
          "kind": "data"
        },
        {
          "path": "~/.config/goose/secrets.yaml",
          "kind": "credentials"
        },
        {
          "path": "~/.local/share/goose",
          "kind": "data"
        },
        {
          "path": "~/.local/share/goose/sessions/sessions.db",
          "kind": "data"
        },
        {
          "path": "~/.local/state/goose/logs",
          "kind": "logs"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash"
        },
        {
          "channel": "brew",
          "command": "brew install block-goose-cli"
        }
      ],
      "docs": "https://goose-docs.ai/docs/guides/logs"
    },
    {
      "id": "amp",
      "name": "Amp",
      "vendor": "Sourcegraph",
      "homepage": "https://ampcode.com",
      "kind": "cli",
      "binaries": [
        "amp"
      ],
      "packages": [
        "ampcode/tap/ampcode",
        "@sourcegraph/amp"
      ],
      "paths": [
        {
          "path": "~/.amp/bin",
          "kind": "program"
        },
        {
          "path": "~/.config/amp",
          "kind": "config"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://ampcode.com/install.sh | bash"
        },
        {
          "channel": "brew",
          "command": "brew install ampcode/tap/ampcode"
        }
      ],
      "docs": "https://ampcode.com/docs/cli/settings"
    },
    {
      "id": "crush",
      "name": "Crush",
      "vendor": "Charmbracelet",
      "homepage": "https://github.com/charmbracelet/crush",
      "kind": "cli",
      "binaries": [
        "crush"
      ],
      "packages": [
        "@charmland/crush",
        "charmbracelet/tap/crush"
      ],
      "paths": [
        {
          "path": "~/.config/crush",
          "kind": "config"
        },
        {
          "path": "~/.local/share/crush",
          "kind": "data"
        },
        {
          "path": "~/.cache/crush",
          "kind": "cache"
        },
        {
          "path": "~/.crush/commands",
          "kind": "config"
        }
      ],
      "install": [
        {
          "channel": "brew",
          "command": "brew install charmbracelet/tap/crush"
        },
        {
          "channel": "npm",
          "command": "npm install -g @charmland/crush"
        },
        {
          "channel": "go",
          "command": "go install github.com/charmbracelet/crush@latest"
        }
      ],
      "docs": "https://github.com/charmbracelet/crush"
    },
    {
      "id": "copilot-cli",
      "name": "GitHub Copilot CLI",
      "vendor": "GitHub",
      "homepage": "https://github.com/github/copilot-cli",
      "kind": "cli",
      "binaries": [
        "copilot"
      ],
      "packages": [
        "@github/copilot",
        "copilot-cli"
      ],
      "paths": [
        {
          "path": "~/.copilot",
          "kind": "data"
        },
        {
          "path": "~/.copilot/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.copilot/config.json",
          "kind": "data"
        },
        {
          "path": "~/.copilot/copilot-instructions.md",
          "kind": "config"
        },
        {
          "path": "~/.copilot/mcp-config.json",
          "kind": "config"
        },
        {
          "path": "~/.copilot/lsp-config.json",
          "kind": "config"
        },
        {
          "path": "~/.copilot/providers.json",
          "kind": "credentials"
        },
        {
          "path": "~/.copilot/session-state",
          "kind": "data"
        },
        {
          "path": "~/.copilot/session-store.db",
          "kind": "data"
        },
        {
          "path": "~/.copilot/logs",
          "kind": "logs"
        },
        {
          "path": "~/.copilot/mcp-oauth-config",
          "kind": "credentials"
        },
        {
          "path": "~/.copilot/mcp-secrets",
          "kind": "credentials"
        },
        {
          "path": "~/Library/Caches/copilot",
          "kind": "cache"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://gh.io/copilot-install | bash"
        },
        {
          "channel": "brew",
          "command": "brew install copilot-cli"
        },
        {
          "channel": "npm",
          "command": "npm install -g @github/copilot"
        }
      ],
      "docs": "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference"
    },
    {
      "id": "qwen-code",
      "name": "Qwen Code",
      "vendor": "Alibaba Cloud (Qwen)",
      "homepage": "https://github.com/QwenLM/qwen-code",
      "kind": "cli",
      "binaries": [
        "qwen"
      ],
      "packages": [
        "@qwen-code/qwen-code",
        "qwen-code"
      ],
      "paths": [
        {
          "path": "~/.local/lib/qwen-code",
          "kind": "program"
        },
        {
          "path": "~/.qwen",
          "kind": "data"
        },
        {
          "path": "~/.qwen/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.qwen/oauth_creds.json",
          "kind": "credentials"
        },
        {
          "path": "~/.qwen/tmp",
          "kind": "data"
        },
        {
          "path": "~/.qwen/file-history",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash"
        },
        {
          "channel": "npm",
          "command": "npm install -g @qwen-code/qwen-code@latest"
        },
        {
          "channel": "brew",
          "command": "brew install qwen-code"
        }
      ],
      "uninstallCommand": "npm uninstall -g @qwen-code/qwen-code",
      "docs": "https://github.com/QwenLM/qwen-code/blob/main/docs/users/support/Uninstall.md"
    },
    {
      "id": "cline",
      "name": "Cline CLI",
      "vendor": "Cline Bot Inc.",
      "homepage": "https://cline.bot",
      "kind": "cli",
      "binaries": [
        "cline"
      ],
      "packages": [
        "cline"
      ],
      "paths": [
        {
          "path": "~/.cline",
          "kind": "data"
        },
        {
          "path": "~/.cline/data",
          "kind": "data"
        },
        {
          "path": "~/.cline/data/settings",
          "kind": "config"
        },
        {
          "path": "~/.cline/data/settings/providers.json",
          "kind": "credentials"
        },
        {
          "path": "~/.cline/data/sessions",
          "kind": "data"
        },
        {
          "path": "~/.cline/data/db",
          "kind": "data"
        },
        {
          "path": "~/.cline/data/logs",
          "kind": "logs"
        },
        {
          "path": "~/.cline/worktrees",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "npm",
          "command": "npm install -g cline"
        }
      ],
      "docs": "https://docs.cline.bot/cli/cli-reference"
    },
    {
      "id": "droid",
      "name": "Droid CLI",
      "vendor": "Factory",
      "homepage": "https://factory.ai",
      "kind": "cli",
      "binaries": [
        "droid"
      ],
      "packages": [
        "droid"
      ],
      "paths": [
        {
          "path": "~/.factory",
          "kind": "data"
        },
        {
          "path": "~/.factory/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.factory/settings.local.json",
          "kind": "config"
        },
        {
          "path": "~/.factory/specs",
          "kind": "data"
        },
        {
          "path": "~/.factory/worktrees",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://app.factory.ai/cli | sh"
        },
        {
          "channel": "brew",
          "command": "brew install --cask droid"
        },
        {
          "channel": "npm",
          "command": "npm install -g droid"
        }
      ],
      "docs": "https://docs.factory.com/droid-cli/quickstart"
    },
    {
      "id": "kilo-cli",
      "name": "Kilo Code CLI",
      "vendor": "Kilo Code",
      "homepage": "https://kilo.ai",
      "kind": "cli",
      "binaries": [
        "kilo",
        "kilocode"
      ],
      "packages": [
        "@kilocode/cli",
        "Kilo-Org/tap/kilo"
      ],
      "paths": [
        {
          "path": "~/.kilo/bin",
          "kind": "program"
        },
        {
          "path": "~/.kilo",
          "kind": "data"
        },
        {
          "path": "~/.config/kilo",
          "kind": "config"
        },
        {
          "path": "~/.local/share/kilo",
          "kind": "data"
        },
        {
          "path": "~/.local/share/kilo/log",
          "kind": "logs"
        },
        {
          "path": "~/.local/state/kilo",
          "kind": "data"
        },
        {
          "path": "~/.cache/kilo",
          "kind": "cache"
        },
        {
          "path": "~/.kilocode",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "npm",
          "command": "npm install -g @kilocode/cli"
        },
        {
          "channel": "script",
          "command": "curl -fsSL https://kilo.ai/cli/install | bash"
        },
        {
          "channel": "brew",
          "command": "brew install Kilo-Org/tap/kilo"
        }
      ],
      "uninstallCommand": "kilo uninstall",
      "docs": "https://kilo.ai/docs/code-with-ai/platforms/cli"
    },
    {
      "id": "openhands-cli",
      "name": "OpenHands CLI",
      "vendor": "OpenHands (All Hands AI)",
      "homepage": "https://github.com/OpenHands/OpenHands-CLI",
      "kind": "cli",
      "binaries": [
        "openhands"
      ],
      "packages": [
        "openhands"
      ],
      "paths": [
        {
          "path": "~/.openhands",
          "kind": "data"
        },
        {
          "path": "~/.openhands/agent_settings.json",
          "kind": "config"
        },
        {
          "path": "~/.openhands/cli_config.json",
          "kind": "config"
        },
        {
          "path": "~/.openhands/mcp.json",
          "kind": "config"
        },
        {
          "path": "~/.openhands/conversations",
          "kind": "data"
        },
        {
          "path": "~/.openhands/projects",
          "kind": "data"
        },
        {
          "path": "~/.openhands/cache",
          "kind": "cache"
        }
      ],
      "install": [
        {
          "channel": "uv",
          "command": "uv tool install openhands --python 3.12"
        },
        {
          "channel": "script",
          "command": "curl -fsSL https://install.openhands.dev/install.sh | sh"
        }
      ],
      "docs": "https://docs.openhands.dev/openhands/usage/cli/installation"
    },
    {
      "id": "continue-cli",
      "name": "Continue CLI",
      "vendor": "Continue",
      "homepage": "https://continue.dev",
      "kind": "cli",
      "binaries": [
        "cn"
      ],
      "packages": [
        "@continuedev/cli"
      ],
      "paths": [
        {
          "path": "~/.continue",
          "kind": "data"
        },
        {
          "path": "~/.continue/config.yaml",
          "kind": "config"
        },
        {
          "path": "~/.continue/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.continue/auth.json",
          "kind": "credentials"
        },
        {
          "path": "~/.continue/sessions",
          "kind": "data"
        },
        {
          "path": "~/.continue/logs",
          "kind": "logs"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh | bash"
        },
        {
          "channel": "npm",
          "command": "npm i -g @continuedev/cli"
        }
      ],
      "docs": "https://github.com/continuedev/continue/blob/main/extensions/cli/README.md"
    },
    {
      "id": "kimi-code",
      "name": "Kimi Code CLI",
      "vendor": "Moonshot AI",
      "homepage": "https://www.kimi.com/code/docs/",
      "kind": "cli",
      "binaries": [
        "kimi"
      ],
      "packages": [
        "@moonshot-ai/kimi-code",
        "kimi-code",
        "kimi-cli"
      ],
      "paths": [
        {
          "path": "~/.kimi-code",
          "kind": "data"
        },
        {
          "path": "~/.kimi-code/bin",
          "kind": "program"
        },
        {
          "path": "~/.kimi-code/config.toml",
          "kind": "config"
        },
        {
          "path": "~/.kimi-code/tui.toml",
          "kind": "config"
        },
        {
          "path": "~/.kimi-code/mcp.json",
          "kind": "config"
        },
        {
          "path": "~/.kimi-code/credentials",
          "kind": "credentials"
        },
        {
          "path": "~/.kimi-code/sessions",
          "kind": "data"
        },
        {
          "path": "~/.kimi-code/user-history",
          "kind": "data"
        },
        {
          "path": "~/.kimi-code/logs",
          "kind": "logs"
        },
        {
          "path": "~/.kimi-code/updates",
          "kind": "cache"
        },
        {
          "path": "~/.kimi",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        },
        {
          "channel": "npm",
          "command": "npm install -g @moonshot-ai/kimi-code"
        },
        {
          "channel": "brew",
          "command": "brew install kimi-code"
        }
      ],
      "uninstallCommand": "npm uninstall -g @moonshot-ai/kimi-code",
      "docs": "https://moonshotai.github.io/kimi-code/en/configuration/data-locations"
    },
    {
      "id": "iflow-cli",
      "name": "iFlow CLI",
      "vendor": "iFlow AI",
      "homepage": "https://cli.iflow.cn",
      "kind": "cli",
      "binaries": [
        "iflow"
      ],
      "packages": [
        "@iflow-ai/iflow-cli",
        "iflow-cli"
      ],
      "paths": [
        {
          "path": "~/.iflow",
          "kind": "data"
        },
        {
          "path": "~/.iflow/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.iflow/commands",
          "kind": "config"
        },
        {
          "path": "~/.iflow/output-styles",
          "kind": "config"
        },
        {
          "path": "~/.iflow/snapshots",
          "kind": "data"
        },
        {
          "path": "~/.iflow/cache",
          "kind": "cache"
        }
      ],
      "install": [
        {
          "channel": "script",
          "command": "bash -c \"$(curl -fsSL https://cloud.iflow.cn/iflow-cli/install.sh)\""
        },
        {
          "channel": "brew",
          "command": "brew tap iflow-ai/iflow-cli && brew install iflow-cli"
        },
        {
          "channel": "npm",
          "command": "npm i -g @iflow-ai/iflow-cli"
        }
      ],
      "uninstallCommand": "npm uninstall -g @iflow-ai/iflow-cli",
      "docs": "https://github.com/iflow-ai/iflow-cli",
      "note": "官方已于 2026-04-17 停止服务；条目保留，用于清理它留下的数据。"
    },
    {
      "id": "codebuddy-code",
      "name": "CodeBuddy Code CLI",
      "vendor": "Tencent",
      "homepage": "https://www.codebuddy.ai",
      "kind": "cli",
      "binaries": [
        "codebuddy",
        "cbc",
        "codebuddy-code"
      ],
      "packages": [
        "@tencent-ai/codebuddy-code",
        "codebuddy-code"
      ],
      "paths": [
        {
          "path": "~/.codebuddy",
          "kind": "config"
        },
        {
          "path": "~/.codebuddy/settings.json",
          "kind": "config"
        },
        {
          "path": "~/.codebuddy/.mcp.json",
          "kind": "config"
        },
        {
          "path": "~/.codebuddy/skills",
          "kind": "config"
        },
        {
          "path": "~/.local/bin/codebuddy",
          "kind": "program"
        },
        {
          "path": "~/.local/share/codebuddy",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "npm",
          "command": "npm install -g @tencent-ai/codebuddy-code"
        },
        {
          "channel": "brew",
          "command": "brew tap Tencent-CodeBuddy/tap && brew install codebuddy-code"
        },
        {
          "channel": "script",
          "command": "curl -fsSL https://www.codebuddy.cn/cli/install.sh | bash"
        }
      ],
      "uninstallCommand": "npm uninstall -g @tencent-ai/codebuddy-code",
      "docs": "https://www.codebuddy.ai/docs/cli/installation"
    },
    {
      "id": "auggie",
      "name": "Auggie CLI",
      "vendor": "Augment Code",
      "homepage": "https://www.augmentcode.com",
      "kind": "cli",
      "binaries": [
        "auggie"
      ],
      "packages": [
        "@augmentcode/auggie"
      ],
      "paths": [
        {
          "path": "~/.augment",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "npm",
          "command": "npm install -g @augmentcode/auggie@latest"
        }
      ],
      "docs": "https://docs.augmentcode.com/cli/reference"
    },
    {
      "id": "kiro-cli",
      "name": "Kiro CLI",
      "vendor": "Amazon Web Services",
      "homepage": "https://kiro.dev",
      "kind": "cli",
      "binaries": [
        "kiro-cli",
        "kiro-cli-chat"
      ],
      "packages": [
        "kiro-cli"
      ],
      "paths": [
        {
          "path": "~/.kiro",
          "kind": "data"
        }
      ],
      "install": [
        {
          "channel": "brew",
          "command": "brew install kiro-cli"
        },
        {
          "channel": "script",
          "command": "curl -fsSL https://cli.kiro.dev/install | bash"
        }
      ],
      "uninstallCommand": "kiro-cli uninstall",
      "docs": "https://kiro.dev/docs/getting-started/installation"
    }
  ]
}
"""#,
    ]
}
