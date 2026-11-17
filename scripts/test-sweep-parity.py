#!/usr/bin/env python3
"""把 `acm sweep scan` 和 BuildSweep 放在同一棵目录树上对拍。

「项目清理」的只读引擎是照着 BuildSweep 移植的。这个脚本在 mktemp 出来的假家目录里
搭一棵覆盖各种情况的目录树，让两边各扫一遍，逐项比较结论、原因、指纹和安装包信息。
两边都只做只读扫描；除了自己建的临时目录，不写任何东西。

BuildSweep 的位置：环境变量 BUILDSWEEP_SOURCE（含 buildsweep.py 的目录），
否则问 PATH 上的 `buildsweep --json doctor`。两处都没有时跳过，退出码 0。
"""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parent.parent
ITEM_FIELDS = [
    "id", "path", "parent", "project", "category", "status", "reason",
    "retained_ids", "installer", "snapshot", "processes",
]
PLAN_FIELDS = ["schema_version", "root", "root_identity", "policy", "summary", "warnings"]

passed = 0
failures = []


def check(name, condition, detail=""):
    global passed
    if condition:
        passed += 1
        print("ok   " + name)
    else:
        failures.append(name)
        print("FAIL " + name)
        for line in str(detail).splitlines()[:40]:
            print("     " + line)


def locate_reference():
    source = os.environ.get("BUILDSWEEP_SOURCE")
    if not source:
        launcher = shutil.which("buildsweep")
        if not launcher:
            return None
        result = subprocess.run([launcher, "--json", "doctor"], capture_output=True, text=True)
        try:
            source = json.loads(result.stdout)["data"]["source"]
        except (ValueError, KeyError):
            return None
    entry = Path(source) / "buildsweep.py"
    return entry if entry.is_file() else None


def build_acm():
    environment = dict(os.environ)
    xcode = "/Applications/Xcode.app/Contents/Developer"
    if "DEVELOPER_DIR" not in environment and os.path.isdir(xcode):
        environment["DEVELOPER_DIR"] = xcode
    build = subprocess.run(["swift", "build", "--product", "acm"], cwd=REPO, env=environment,
                           capture_output=True, text=True)
    if build.returncode:
        sys.exit("构建失败：\n" + (build.stdout + build.stderr)[-3000:])
    where = subprocess.run(["swift", "build", "--product", "acm", "--show-bin-path"], cwd=REPO,
                           env=environment, capture_output=True, text=True, check=True)
    return Path(where.stdout.strip()) / "acm"


# ---------- 目录树 ----------

def write(path, data=b"data"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)
    return path


def swift_cache(project):
    write(project / "Package.swift", "// swift-tools-version: 6.0\n")
    (project / ".build/artifacts").mkdir(parents=True)
    write(project / ".build/workspace-state.json", "{}")
    write(project / ".build/object.o", "rebuildable object")
    return project / ".build"


def bundle(path, identifier, version, executable=bytes.fromhex("cffaedfe0c000001"), extra=None):
    info = {"CFBundleExecutable": "Product"}
    if identifier:
        info["CFBundleIdentifier"] = identifier
    if version:
        info["CFBundleShortVersionString"] = version
    info.update(extra or {})
    write(path / "Contents/Info.plist", plistlib.dumps(info))
    write(path / "Contents/MacOS/Product", executable)


def app_zip(path, members, compression=zipfile.ZIP_DEFLATED):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression) as archive:
        for name, data in members:
            archive.writestr(name, data)


def git(repo, *arguments):
    subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-c", "init.templateDir=", "-C", str(repo)] + list(arguments),
        capture_output=True, check=True,
    )


def build_tree(root):
    """返回几个之后要用到的路径。"""
    plist = plistlib.dumps({"CFBundleIdentifier": "test.product", "CFBundleName": "Product"})

    # 有生成依据的缓存
    swift_cache(root / "SwiftApp")
    write(root / "SwiftApp/Sources/main.swift", "print(42)")
    os.symlink("/usr/bin/true", root / "SwiftApp/.build/external-link")
    os.symlink("object.o", root / "SwiftApp/.build/relative-link")
    os.link(root / "SwiftApp/.build/object.o", root / "SwiftApp/.build/hard-link.o")
    write(root / "SwiftApp/.build/.DS_Store", "noise")

    write(root / "Web/package.json", "{}")
    write(root / "Web/node_modules/.package-lock.json", "{}")
    write(root / "Web/node_modules/left-pad/index.js", "module.exports = 1")
    write(root / "Web/next.config.mjs", "")
    write(root / "Web/.next/build-manifest.json", "{}")
    write(root / "Pnpm/package.json", "{}")
    write(root / "Pnpm/node_modules/.pnpm/registry/pkg/index.js")
    write(root / "Orphan/node_modules/.modules.yaml", "")
    write(root / "Orphan/.DS_Store", "noise")
    write(root / "Mono/turbo.json", "{}")
    write(root / "Mono/packages/ui/package.json", "{}")
    write(root / "Mono/packages/ui/.turbo/cache/a.log")
    write(root / "Py/pyproject.toml", "")
    write(root / "Py/pkg/__pycache__/mod.cpython-312.pyc", "bytecode")
    write(root / "Py/pkg/mod.py", "x = 1")

    # 名字像缓存但没有依据
    write(root / "Loose/.build/notes.txt", "hand-written")
    (root / "Loose/.build-old").mkdir()
    write(root / "Loose/vendor/node_modules/pkg/index.js")
    write(root / "Loose/tools/node_modules/.package-lock.json", "{}")
    write(root / "Loose/tools/README", "not a project")
    write(root / "Loose/.next/x")
    write(root / "Py/odd/__pycache__/mod.cpython-312.pyc", "bytecode")
    write(root / "Py/odd/__pycache__/notes.txt", "not generated")
    write(root / "Py/nested/__pycache__/sub/mod.pyc", "bytecode")
    write(root / "Py/.pytest_cache/v/cache/lastfailed", "{}")

    # 保护条件
    swift_cache(root / "NestedRepo")
    (root / "NestedRepo/.build/checkouts/Dependency/.git").mkdir(parents=True)
    swift_cache(root / "Tracked")
    git(root / "Tracked", "init", "-q")
    git(root / "Tracked", "add", "Package.swift", ".build/object.o")
    swift_cache(root / "Ignored")
    write(root / "Ignored/.gitignore", ".build\n")
    git(root / "Ignored", "init", "-q")
    git(root / "Ignored", "add", "Package.swift", ".gitignore")
    swift_cache(root / "Glob [old]*")
    git(root / "Glob [old]*", "init", "-q")
    git(root / "Glob [old]*", "add", ".build/object.o")
    swift_cache(root / "Fifo")
    os.mkfifo(root / "Fifo/.build/pipe")
    swift_cache(root / "Linked/Real")
    os.symlink(root / "Linked/Real/.build", root / "Linked/.build")
    os.symlink(root / "Linked/Real", root / "Linked/Alias")

    # 不往里找的目录
    for name in ["Sources", "assets", "data", "backup", ".ssh", "docs", "design", "fixtures"]:
        swift_cache(root / "Guarded" / name / "Inner")
    write(root / "Guarded/certificate.pem", "private fixture")

    # 少见的名字
    swift_cache(root / "名字 with space" / "caf\u00e9")
    swift_cache(root / "nfd-cafe\u0301")
    swift_cache(root / "nfc-caf\u00e9")
    swift_cache(root / "emoji-\U0001F600")
    swift_cache(root / "line\nbreak")
    swift_cache(root / "quote\"back\\slash")
    write(root / "emoji-\U0001F600/.build/中文\U0001F680.o", "x")

    # 安装包
    release = root / "Dist/release"
    for name, data in [
        ("Product-1.9.0-arm64.dmg", "old"), ("Product-1.10.0-arm64.dmg", "new"),
        ("Product-1.2.0-x86_64.dmg", "intel"), ("Product-1.10.0-rc.1-arm64.dmg", "old preview"),
        ("Product-2.0.0-beta.2-arm64.dmg", "new preview"), ("Product-2.0.0-beta.1-arm64.dmg", "older preview"),
        ("Product-2.0.0-alpha-arm64.dmg", "alpha"), ("Other_3.1.4_x64-setup.exe", "windows"),
        ("Other_3.1.3_amd64-setup.exe", "windows old"), ("My Tool-1.2.3-macos-aarch64.pkg", "pkg"),
        ("My Tool v1.2.4 darwin universal.pkg", "pkg new"), ("Installer.pkg", "no version"),
        ("1.2.3.dmg", "no product"), ("notes-1.0.0.txt", "not an installer"),
        ("Source-backup-1.0.0.zip", "not a zip"), ("Preview-1.0.0-dev.3.msi", "dev"),
        ("Preview-1.0.0-preview.msi", "preview"), ("Upper-1.0.0.DMG", "upper"), ("Upper-1.0.1.Dmg", "upper"),
        ("Bundle-1.0.0.app.zip", "by name"), ("Bundle-1.1.0.app.zip", "by name"),
    ]:
        write(release / name, data)
    write(root / "Dist/Package.swift", "")
    write(root / "Dist/downloaded/Product-1.10.0-arm64.dmg", "new")
    write(root / "Dist/acceptance/copy/Product-1.10.0-arm64.dmg", "new")
    write(root / "Dist/elsewhere/Product-2.0.0-beta.2-arm64.dmg", "different content")
    write(root / "NoProject/a/Thing-1.0.0.dmg", "a")
    write(root / "NoProject/b/Thing-2.0.0.dmg", "b")

    app_zip(release / "Zipped-1.0.0-arm64.zip", [
        ("Zipped.app/Contents/Info.plist", plist), ("Zipped.app/Contents/MacOS/Zipped", b"binary"),
    ])
    app_zip(release / "Zipped-1.1.0-arm64.zip", [
        ("Zipped.app/Contents/MacOS/Zipped", b"binary 2"), ("Zipped.app/Contents/Info.plist", plist),
    ], zipfile.ZIP_STORED)
    app_zip(release / "TwoApps-1.0.0.zip", [
        ("A.app/Contents/Info.plist", plist), ("B.app/Contents/Info.plist", plist),
    ])
    app_zip(release / "NestedApp-1.0.0.zip", [("backup/Old.app/Contents/Info.plist", plist)])
    app_zip(release / "NoIdentity-1.0.0.zip", [
        ("X.app/Contents/Info.plist", plistlib.dumps({"CFBundleName": "X"})),
    ])
    app_zip(release / "Design-1.0.0.zip", [("mockups/home.png", b"png")])
    app_zip(release / "BinaryPlist-1.0.0.zip", [
        ("B.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test.binary"}, fmt=plistlib.FMT_BINARY)),
    ])
    app_zip(release / "NoVersion.zip", [("Z.app/Contents/Info.plist", plist)])
    # 条目数超过 65535：压缩包结尾用的是 ZIP64 记录。
    app_zip(release / "Many-1.0.0.zip",
            [("Many.app/Contents/Info.plist", plist)] + [("Many.app/r/%05d" % n, b"") for n in range(65600)],
            zipfile.ZIP_STORED)
    app_zip(release / "Many-1.1.0.zip",
            [("Many.app/r/%05d" % n, b"") for n in range(65600)] + [("Many.app/Contents/Info.plist", plist)],
            zipfile.ZIP_STORED)
    write(release / "Prefixed-1.0.0.zip", b"#" * 700 + (release / "Zipped-1.0.0-arm64.zip").read_bytes())
    write(release / "Cut-1.0.0.zip", (release / "Zipped-1.0.0-arm64.zip").read_bytes()[:-30])

    bundle(root / "Dist/copy-1.0.0/Product.app", "test.product", "1.0.0")
    bundle(root / "Dist/copy-1.1.0/Product.app", "test.product", "1.1.0", extra={"CFBundleVersion": "42"})
    bundle(root / "Dist/intel/Product.app", "test.product", "0.9.0", bytes.fromhex("cffaedfe07000001"))
    bundle(root / "Dist/fat/Product.app", "test.product", "0.9.0", bytes.fromhex("cafebabe00000002"))
    bundle(root / "Dist/script/Product.app", "test.product", "0.8.0", b"#!/bin/sh\n")
    bundle(root / "Dist/vague/Vague.app", "test.vague", "2")
    bundle(root / "Dist/anonymous/Anon.app", None, "1.0.0")
    (root / "Dist/hollow/Hollow.app/Contents").mkdir(parents=True)
    write(root / "Dist/file.app", "a file, not a bundle")

    return {
        "exclude_inside": root / "SwiftApp/.build/object.o",
        "exclude_whole": root / "Web",
        "held_file": root / "Pnpm/node_modules/.pnpm/registry/pkg/index.js",
        "busy_project": root / "Py",
        "unreadable": root / "Unreadable",
    }


# ---------- 运行与比较 ----------

def run_json(command, environment=None):
    result = subprocess.run(command, capture_output=True, text=True, cwd="/", env=environment)
    try:
        return result.returncode, json.loads(result.stdout)
    except ValueError:
        return result.returncode, {"ok": False, "error": {"code": "not_json", "message": result.stdout + result.stderr}}


def compare(name, acm, reference, loose_reason=()):
    """逐项比较两边的计划。`loose_reason` 里的路径只比结论，不比原因文字。"""
    if not (acm.get("ok") and reference.get("ok")):
        check(name + "：两边都成功", False, json.dumps([acm.get("error"), reference.get("error")], ensure_ascii=False))
        return
    ours, theirs = acm["data"], reference["data"]
    problems = []
    for field in PLAN_FIELDS:
        if ours.get(field) != theirs.get(field):
            problems.append("%s: acm=%r buildsweep=%r" % (field, ours.get(field), theirs.get(field)))
    if [x["path"] for x in ours["items"]] != [x["path"] for x in theirs["items"]]:
        mine, other = {x["path"] for x in ours["items"]}, {x["path"] for x in theirs["items"]}
        problems.append("候选项不同：只有 acm %r；只有 buildsweep %r；或顺序不同" % (sorted(mine - other), sorted(other - mine)))
    else:
        for a, b in zip(ours["items"], theirs["items"]):
            for field in ITEM_FIELDS:
                if field == "reason" and a["path"] in loose_reason:
                    continue
                if a.get(field) != b.get(field):
                    problems.append("%r %s: acm=%r buildsweep=%r" % (a["path"], field, a.get(field), b.get(field)))
    check("%s（%d 项）" % (name, len(theirs["items"])), not problems, "\n".join(problems))
    return ours


def main():
    reference_entry = locate_reference()
    if reference_entry is None:
        print("已跳过：找不到 BuildSweep（可设置 BUILDSWEEP_SOURCE 指向含 buildsweep.py 的目录）。")
        return 0
    if not shutil.which("git"):
        print("已跳过：找不到 git。")
        return 0
    acm_binary = build_acm()

    base = Path(tempfile.mkdtemp(prefix="acm-sweep-parity.", dir="/tmp")).resolve()
    children = []
    try:
        home = base / "home"
        root = home / "Projects/workspace"
        root.mkdir(parents=True)
        paths = build_tree(root)
        state = base / "buildsweep-state"
        reference_env = {**os.environ, "BUILDSWEEP_STATE_DIR": str(state)}

        def both(options):
            ours = run_json([str(acm_binary), "sweep", "scan", str(root), "--json", "--home", str(home)] + options)
            theirs = run_json([sys.executable, "-B", str(reference_entry), "--json", "scan", str(root)] + options,
                              reference_env)
            return ours[1], theirs[1]

        plan = compare("不看闲置时间", *both(["--idle-hours", "0"]))
        if plan:
            statuses = {x["status"] for x in plan["items"]}
            categories = {x["category"] for x in plan["items"]}
            check("目录树覆盖四种结论", statuses == {"cleanup", "keep", "review", "blocked"}, statuses)
            check("目录树覆盖全部类别", len(categories) == 7, categories)
        compare("默认闲置 24 小时", *both([]))
        compare("条目上限 3", *both(["--idle-hours", "0", "--max-entries", "3"]))
        compare("排除候选项内部的文件和整个项目", *both([
            "--idle-hours", "0", "--exclude", str(paths["exclude_inside"]), "--exclude", str(paths["exclude_whole"]),
        ]))

        # 缓存里有读不了的子目录：两边都不清理，但系统错误的文字各写各的。
        swift_cache(paths["unreadable"])
        locked = paths["unreadable"] / ".build/locked"
        locked.mkdir()
        locked.chmod(0)
        try:
            unreadable = str((paths["unreadable"] / ".build").relative_to(root))
            compare("缓存里有读不了的目录", *both(["--idle-hours", "0"]), loose_reason={unreadable})
        finally:
            locked.chmod(0o700)
            shutil.rmtree(paths["unreadable"])

        # 真的有进程开着缓存里的文件；另一个开发工具的工作目录在某个项目里。
        holder = subprocess.Popen(
            [sys.executable, "-c", "import sys,time; f=open(sys.argv[1]); print('ready',flush=True); time.sleep(120)",
             str(paths["held_file"])], stdout=subprocess.PIPE, text=True, cwd="/")
        children.append(holder)
        worker = subprocess.Popen(
            [sys.executable, "-c", "import time; print('ready',flush=True); time.sleep(120)"],
            stdout=subprocess.PIPE, text=True, cwd=str(paths["busy_project"]))
        children.append(worker)
        holder.stdout.readline()
        worker.stdout.readline()
        busy = compare("进程占用", *both(["--idle-hours", "0"]))
        if busy:
            users = {x["path"]: [p["pid"] for p in x.get("processes", [])] for x in busy["items"]}
            check("打开的文件被认出来", users.get("Pnpm/node_modules") == [holder.pid], users.get("Pnpm/node_modules"))
            check("项目里的开发工具被认出来", users.get("Py/pkg/__pycache__") == [worker.pid], users.get("Py/pkg/__pycache__"))

        # 被拒绝的扫描根和策略：错误码一致。这些在任何扫描开始之前就被拒绝。
        for label, arguments in [
            ("根目录", ["/"]), ("/tmp", ["/tmp"]), ("系统目录", ["/usr/lib"]),
            ("真实家目录", [os.path.expanduser("~")]), ("文件当目录", [str(root / "SwiftApp/Package.swift")]),
            ("不存在的目录", [str(root / "missing")]),
            ("闲置时间不是有限数值", [str(root), "--idle-hours", "nan"]),
            ("闲置时间为负", [str(root), "--idle-hours", "-1"]),
            ("条目上限为零", [str(root), "--max-entries", "0"]),
        ]:
            ours = run_json([str(acm_binary), "sweep", "scan", "--json"] + arguments)
            theirs = run_json([sys.executable, "-B", str(reference_entry), "--json", "scan"] + arguments, reference_env)
            codes = (ours[1].get("error", {}).get("code"), theirs[1].get("error", {}).get("code"))
            check("拒绝：" + label, codes[0] == codes[1] and codes[0] and ours[0] != 0, codes)

        check("BuildSweep 没有留下状态目录", not state.exists(), state)
    finally:
        for child in children:
            child.terminate()
            child.wait(timeout=10)
            child.stdout.close()
        if str(base).startswith("/private/tmp/acm-sweep-parity."):
            shutil.rmtree(base, ignore_errors=True)

    print("\n通过 %d 条，失败 %d 条" % (passed, len(failures)))
    for name in failures:
        print("  " + name)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
