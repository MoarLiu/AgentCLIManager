import Foundation
import Testing
@testable import ACMCore

/// 归属判定。每一条都对应一个在真机上见过、判错会出事的情形。
@Suite struct AttributionTests {

    // MARK: 绝不能判成残留的

    @Test func codexDirIsNotResidueWhileChatGPTAppIsInstalled() throws {
        // ChatGPT.app 的 bundle id 是 com.openai.codex；没有 codex 命令不代表 ~/.codex 没人用
        let fx = try Fixture()
        fx.app("ChatGPT", bundleID: "com.openai.codex")
        fx.file(".codex/sessions/a.jsonl")

        let report = scan(fx)
        let hit = try #require(find(report, fx.path(".codex")))
        #expect(hit.group.section == .managedByApp)
        #expect(hit.artifact.claim == .usedByApp)
        #expect(!hit.artifact.defaultSelected)
        #expect(report.groups(in: .residue).isEmpty)
    }

    @Test func cacheNamedByCodenameBundleIDBelongsToItsApp() throws {
        // Grok Bot.app 的 bundle id 是 com.anysphere.sand——按厂商名猜会算到 Cursor 头上
        let fx = try Fixture()
        fx.app("Grok Bot", bundleID: "com.anysphere.sand")
        fx.file("Library/Caches/com.anysphere.sand/Cache.db")
        fx.file("Library/Caches/com.anysphere.sand.ShipIt/update.zip")
        fx.file("Library/Preferences/com.anysphere.sand.plist")

        let report = scan(fx)
        #expect(find(report, fx.path("Library/Caches/com.anysphere.sand")) == nil)
        #expect(find(report, fx.path("Library/Caches/com.anysphere.sand.ShipIt")) == nil)
        #expect(find(report, fx.path("Library/Preferences/com.anysphere.sand.plist")) == nil)
        #expect(report.groups(in: .residue).isEmpty)
    }

    @Test func dirNamedLikeInstalledAppIsTreatedAsInUse() throws {
        let fx = try Fixture()
        fx.app("WorkBuddy", bundleID: "com.tencent.workbuddy.mac")
        fx.file(".workbuddy/mcp.json")
        fx.file(".workbuddy-computer-use/state.json")

        let report = scan(fx)
        for rel in [".workbuddy", ".workbuddy-computer-use"] {
            let hit = try #require(find(report, fx.path(rel)))
            #expect(hit.group.section == .managedByApp)
            #expect(!hit.artifact.defaultSelected)
        }
    }

    @Test func runtimeRepoWithAgentsMdIsNotAnAgentTool() throws {
        // ~/.nvm 是个 git 仓库，里面有 AGENTS.md
        let fx = try Fixture()
        fx.file(".nvm/AGENTS.md")
        fx.file(".nvm/versions/node/v20.0.0/bin/node", executable: true)
        fx.link(".local/bin/node", to: fx.path(".nvm/versions/node/v20.0.0/bin/node"))

        let report = scan(fx)
        #expect(report.groups(in: .installed).isEmpty)
        #expect(report.groups(in: .otherCLI).contains { $0.binaries.contains { $0.name == "node" } })
    }

    // MARK: 共用

    @Test func dirSharedWithInstalledAppIsLockedButExclusiveSubpathIsNot() throws {
        let fx = try Fixture()
        fx.app("Qoder", bundleID: "com.qoder.app")
        fx.file(".qoder/bin/qodercli/qodercli-1.1.83", executable: true)
        fx.file(".qoder/bin/qodercli/qodercli-1.1.81", executable: true)
        fx.file(".qoder/settings.json")
        fx.link(".local/bin/qodercli", to: fx.path(".qoder/bin/qodercli/qodercli-1.1.83"))

        let report = scan(fx)
        let group = try #require(report.groups(in: .installed).first)
        #expect(group.productID == "qoder-cli")
        #expect(group.version == "1.1.83")

        let root = try #require(find(report, fx.path(".qoder")))
        #expect(root.artifact.claim == .shared)
        #expect(root.artifact.flags.contains(.shared))
        #expect(!root.artifact.defaultSelected)

        // 归属按子路径算：清单声明的 CLI 独占目录可以默认勾选
        let program = try #require(find(report, fx.path(".qoder/bin/qodercli")))
        #expect(program.artifact.claim == .ownedByCLI)
        #expect(program.artifact.defaultSelected)
    }

    @Test func runningToolLocksEveryArtifact() throws {
        let fx = try Fixture()
        let binary = fx.file(".local/share/claude/versions/2.1.0", executable: true)
        fx.link(".local/bin/claude", to: binary)
        fx.file(".claude/settings.json")

        let report = scan(fx, processes: [RunningProcess(pid: 4242, executable: binary)])
        let group = try #require(report.groups(in: .installed).first)
        #expect(group.runningPIDs == [4242])
        #expect(!group.artifacts.isEmpty)
        for artifact in group.artifacts {
            #expect(artifact.flags.contains(.inUse))
            #expect(!artifact.defaultSelected)
        }
    }

    @Test func installedToolSelectsProgramButNotData() throws {
        let fx = try Fixture()
        let binary = fx.file(".local/share/claude/versions/2.1.0", executable: true)
        fx.link(".local/bin/claude", to: binary)
        fx.file(".claude/settings.json")

        let report = scan(fx)
        #expect(try #require(find(report, fx.path(".local/share/claude"))).artifact.defaultSelected)
        #expect(try #require(find(report, fx.path(".local/bin/claude"))).artifact.defaultSelected)
        // 没装桌面 App 时 ~/.claude 不算共用，但数据默认仍然不勾
        let data = try #require(find(report, fx.path(".claude")))
        #expect(data.artifact.claim == .ownedByCLI)
        #expect(!data.artifact.defaultSelected)
    }

    // MARK: 残留

    @Test func catalogedDirIsResidueOnceToolAndAppAreGone() throws {
        let fx = try Fixture()
        fx.file(".cursor/mcp.json")

        let old = try #require(find(scan(fx), fx.path(".cursor")))
        #expect(old.group.section == .residue)
        #expect(old.artifact.claim == .residue)
        #expect(old.artifact.strength == .certain)
        // 顶层目录且清单没声明独占：确定是残留，也不默认勾
        #expect(!old.artifact.defaultSelected)
    }

    @Test func exclusiveResidueIsSelectedOnlyWhenOld() throws {
        let fx = try Fixture()
        fx.file(".codexbar/cache.lock")

        let old = try #require(find(scan(fx, daysLater: 60), fx.path(".codexbar")))
        #expect(old.group.section == .residue)
        #expect(old.artifact.defaultSelected)

        let recent = try #require(find(scan(fx, daysLater: 0), fx.path(".codexbar")))
        #expect(recent.artifact.flags.contains(.recentlyModified))
        #expect(!recent.artifact.defaultSelected)
    }

    @Test func prefixNameMatchDoesNotOverrideCatalog() throws {
        // codexbar 以 codex 开头，但它不是 ChatGPT.app 的东西
        let fx = try Fixture()
        fx.app("ChatGPT", bundleID: "com.openai.codex")
        fx.file(".codexbar/cache.lock")

        let hit = try #require(find(scan(fx), fx.path(".codexbar")))
        #expect(hit.group.section == .residue)
        #expect(hit.group.name == "CodexBar")
    }

    @Test func libraryEntryOfAbsentCatalogedAppIsResidue() throws {
        let fx = try Fixture()
        fx.file("Library/WebKit/com.steipete.codexbar/db")
        fx.file("Library/Caches/com.unknown.vendor/x")

        let report = scan(fx)
        let hit = try #require(find(report, fx.path("Library/WebKit/com.steipete.codexbar")))
        #expect(hit.group.section == .residue)
        #expect(hit.artifact.strength == .certain)
        #expect(hit.artifact.defaultSelected)
        // 不认识的 bundle id 不猜
        #expect(find(report, fx.path("Library/Caches/com.unknown.vendor")) == nil)
    }

    @Test func danglingSymlinkIsResidue() throws {
        let fx = try Fixture()
        fx.link(".aionui", to: fx.path("Library/Application Support/AionUi/aionui"))
        fx.link(".aionui-config", to: fx.path("Library/Application Support/AionUi/config"))

        let report = scan(fx)
        let group = try #require(report.groups(in: .residue).first)
        #expect(group.artifacts.count == 2)
        for artifact in group.artifacts {
            #expect(artifact.flags.contains(.danglingSymlink))
            #expect(artifact.defaultSelected)
        }
    }

    @Test func brokenLauncherScriptIsDetected() throws {
        // 普通文件、内容是一行 exec，主程序已被删——查悬空软链查不出来
        let fx = try Fixture()
        fx.file(".local/bin/alma", "#!/bin/bash\nexec /Applications/Gone.app/Contents/Resources/bun \"$@\"\n", executable: true)
        fx.file(".config/alma/config.json")

        let report = scan(fx)
        let group = try #require(report.groups(in: .residue).first)
        #expect(group.name == "alma")
        let shim = try #require(find(report, fx.path(".local/bin/alma")))
        #expect(shim.artifact.flags.contains(.brokenShim))
        // 同名的配置目录只是推测，不默认勾
        let config = try #require(find(report, fx.path(".config/alma")))
        #expect(config.artifact.strength == .probable)
        #expect(!config.artifact.defaultSelected)
    }

    @Test func catalogedDirHoldingAnInstalledAppsSubdirIsNotResidue() throws {
        // ~/.gemini 在清单里属于 Gemini CLI，但 Antigravity.app 也在里面建了 antigravity/。
        // 没装 gemini 命令不等于这个目录没人用。
        let fx = try Fixture()
        fx.app("Antigravity", bundleID: "com.google.antigravity")
        fx.file(".gemini/antigravity/state.json")
        fx.file(".gemini/config/settings.json")

        let report = scan(fx)
        let hit = try #require(find(report, fx.path(".gemini")))
        #expect(hit.group.section == .managedByApp)
        #expect(hit.artifact.ownerAppName == "Antigravity")
        #expect(!hit.artifact.defaultSelected)
        #expect(report.groups(in: .residue).isEmpty)
    }

    @Test func fileNamedAfterAnAppDoesNotMakeADirectoryShared() throws {
        // ~/.codexbar 里有个 claude-oauth-cache.lock，不代表它是 Claude.app 的
        let fx = try Fixture()
        fx.app("Claude", bundleID: "com.anthropic.claudefordesktop")
        fx.file(".codexbar/claude-oauth-cache.lock")

        let hit = try #require(find(scan(fx), fx.path(".codexbar")))
        #expect(hit.group.section == .residue)
        #expect(hit.group.name == "CodexBar")
    }

    @Test func genericProductNameDoesNotAdoptUnrelatedLibraryEntries() throws {
        // com.BZG.Gemini 是另一个叫 Gemini 的 App，不是 Gemini CLI 的东西
        let fx = try Fixture()
        fx.file(".gemini/settings.json")
        fx.file("Library/WebKit/com.BZG.Gemini/db")
        fx.file("Library/HTTPStorages/com.BZG.Gemini/x")
        fx.file("Library/Application Support/Gemini Notes/x")

        let report = scan(fx)
        #expect(find(report, fx.path(".gemini"))?.group.section == .residue)
        #expect(find(report, fx.path("Library/WebKit/com.BZG.Gemini")) == nil)
        #expect(find(report, fx.path("Library/HTTPStorages/com.BZG.Gemini")) == nil)
        #expect(find(report, fx.path("Library/Application Support/Gemini Notes")) == nil)
    }

    @Test func libraryEntryNamedAfterAnUnidentifiedDirStillGroupsWithIt() throws {
        // 由目录自己的名字推出来的组，仍然可以按名字收拢 Library 里的同名条目
        let fx = try Fixture()
        fx.file(".boltai/mcp.json")
        fx.file("Library/Application Support/BoltAI/data")

        let report = scan(fx)
        let dir = try #require(find(report, fx.path(".boltai")))
        let lib = try #require(find(report, fx.path("Library/Application Support/BoltAI")))
        #expect(dir.group.id == lib.group.id)
        #expect(!lib.artifact.defaultSelected)
    }

    // MARK: 未识别

    @Test func unknownDirWithAgentMarkersIsListedButNeverSelected() throws {
        let fx = try Fixture()
        fx.file(".reasonix/sessions/1.json")
        fx.file(".reasonix/projects/p.json")
        fx.file(".boltai/mcp.json")
        fx.file(".tmeet/config.json")

        for days in [0, 60] {
            let report = scan(fx, daysLater: days)
            for rel in [".reasonix", ".boltai"] {
                let hit = try #require(find(report, fx.path(rel)))
                #expect(hit.group.section == .unidentified)
                #expect(hit.artifact.claim == .candidate)
                #expect(!hit.artifact.defaultSelected)
            }
            // 没有任何 Agent 迹象的目录不列出
            #expect(find(report, fx.path(".tmeet")) == nil)
        }
    }

    @Test func sensitiveDirsNeverAppear() throws {
        let fx = try Fixture()
        fx.file(".ssh/id_ed25519")
        fx.file(".aws/credentials")
        fx.file(".agents/skills/x.md")
        fx.file(".config/gh/hosts.yml")

        let report = scan(fx)
        for rel in [".ssh", ".aws", ".agents", ".config/gh", ".config"] {
            #expect(find(report, fx.path(rel)) == nil)
        }
    }

    // MARK: 包管理器装的

    @Test func npmGlobalPackageUnderNvmIsDetectedFromItsSymlink() throws {
        let fx = try Fixture()
        let prefix = ".nvm/versions/node/v20.0.0"
        fx.file(prefix + "/bin/node", executable: true)
        fx.file(prefix + "/lib/node_modules/npm/bin/npm-cli.js", executable: true)
        fx.link(prefix + "/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js")
        fx.file(prefix + "/lib/node_modules/@openai/codex/bin/codex.js", executable: true)
        fx.file(prefix + "/lib/node_modules/@openai/codex/package.json", #"{"name":"@openai/codex","version":"0.50.0"}"#)
        fx.link(prefix + "/bin/codex", to: "../lib/node_modules/@openai/codex/bin/codex.js")

        let report = scan(fx)
        let group = try #require(report.groups(in: .installed).first)
        #expect(group.productID == "codex")
        #expect(group.channel == .npm)
        #expect(group.version == "0.50.0")

        // 程序以整个包目录为单位
        let package = try #require(find(report, fx.path(prefix + "/lib/node_modules/@openai/codex")))
        #expect(package.artifact.kind == .program)
        #expect(package.artifact.defaultSelected)
        // node 和 npm 自己不算
        #expect(!report.groups.contains { $0.binaries.contains { $0.name == "npm" || $0.name == "node" } })
    }

    @Test func pythonVenvBinIsNotACommandDirectory() throws {
        let fx = try Fixture()
        fx.file(".venv-tool/pyvenv.cfg")
        fx.file(".venv-tool/bin/pytest", executable: true)

        #expect(scan(fx).groups.isEmpty)
    }

    @Test func pathAssignmentsInRcFilesAreFollowedButOtherVarsAreNot() throws {
        let fx = try Fixture()
        fx.file(".zshrc", """
        export NVM_DIR="$HOME/.nvm"
        path=("$HOME/.qoder/entry" ${path:#"$HOME/.qoder/entry"})
        fpath=(~/.grok/completions/zsh $fpath)
        """)
        fx.file(".nvm/nvm.sh", executable: true)
        fx.file(".qoder/entry/qoder", executable: true)
        fx.file(".grok/completions/zsh/_grok", executable: true)

        let dirs = PathProbe.binDirs(env: fx.env()).map(\.path)
        #expect(dirs.contains(fx.path(".qoder/entry")))
        #expect(!dirs.contains(fx.path(".nvm")))
        #expect(!dirs.contains(fx.path(".grok/completions/zsh")))
    }
}

@Suite struct CatalogTests {

    @Test func builtinCatalogLoadsAndIsWellFormed() throws {
        let catalog = Catalog.loadBuiltin()
        #expect(catalog.products.count >= 7)
        #expect(Set(catalog.products.map(\.id)).count == catalog.products.count)
        for product in catalog.products {
            for declared in product.paths ?? [] {
                #expect(declared.path.hasPrefix("~/"), "\(product.id): \(declared.path)")
                #expect(!declared.path.contains(".."), "\(product.id): \(declared.path)")
                #expect(!declared.path.contains("*"), "\(product.id): \(declared.path)")
            }
            if product.kind == .cli {
                #expect(!(product.binaries ?? []).isEmpty, "\(product.id) 没有命令名")
            }
        }
    }

    @Test func builtinCatalogNeverDeclaresAProtectedPath() throws {
        // 清单里写错一条路径不应当能删掉 ~/.config 这类公共目录
        let fx = try Fixture()
        let env = fx.env()
        for product in Catalog.loadBuiltin().products {
            for declared in product.paths ?? [] {
                let path = PathUtil.expand(declared.path, home: env.home)
                #expect(PathSafety.check(path, env: env).allowed, "\(product.id): \(declared.path)")
            }
        }
    }

    @Test func duplicateIDsAndUnknownSchemaAreRejected() {
        let duplicate = #"{"schemaVersion":1,"products":[{"id":"a","name":"A","kind":"cli"},{"id":"a","name":"B","kind":"cli"}]}"#
        #expect(throws: (any Error).self) { try Catalog.decode(Data(duplicate.utf8)) }
        let future = #"{"schemaVersion":2,"products":[]}"#
        #expect(throws: (any Error).self) { try Catalog.decode(Data(future.utf8)) }
    }

    @Test func mostSpecificDeclarationWins() {
        let claim = testCatalog.claim(for: "/h/.grok/auth.json", home: "/h")
        #expect(claim?.declared.kind == .credentials)
        #expect(testCatalog.claim(for: "/h/.grok/sessions/x", home: "/h")?.declared.kind == .data)
        #expect(testCatalog.claim(for: "/h/.grokbot", home: "/h") == nil)
    }

    @Test func userCatalogDropsPathsThatFailPathSafety() throws {
        let fx = try Fixture()
        fx.file("Library/Application Support/AgentCLIManager/catalog.json", """
        {"schemaVersion":1,"products":[{"id":"extra","name":"Extra","kind":"cli","binaries":["extra"],"paths":[
          {"path":"~/.ssh","kind":"data"},
          {"path":"~/.extra-tool","kind":"data"}
        ]}]}
        """)
        let loaded = Catalog.loadAllReporting(env: fx.env())
        let product = try #require(loaded.catalog.product(id: "extra"))
        #expect(product.paths?.map(\.path) == ["~/.extra-tool"])
        #expect(loaded.warnings.contains { $0.contains("~/.ssh") })
    }
}
