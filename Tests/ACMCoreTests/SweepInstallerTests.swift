import Foundation
import Testing
@testable import ACMCore

/// 安装包的识别和版本保留。
@Suite struct SweepInstallerTests {

    @Test func versionsCompareNumericallyAndPerArchitecture() throws {
        let ws = try SweepWorkspace()
        let old = ws.package("Product-1.9.0-arm64.dmg")
        let newest = ws.package("Product-1.10.0-arm64.dmg")
        let intel = ws.package("Product-1.2.0-x86_64.dmg")
        let plan = try ws.scan()
        // 1.10 比 1.9 新（按数字比，不是按字符串）；另一种架构各算各的。
        #expect(plan.item(old)?.status == .cleanup)
        #expect(plan.item(newest)?.status == .keep)
        #expect(plan.item(intel)?.status == .keep)
        #expect(plan.item(old)?.retainedIDs == [try #require(plan.item(newest)).id])
    }

    @Test func newerPreviewDoesNotReplaceLatestStable() throws {
        let ws = try SweepWorkspace()
        let stable = ws.package("Product-1.9.0-arm64.dmg")
        let oldPreview = ws.package("Product-1.9.0-rc.1-arm64.dmg")
        let newPreview = ws.package("Product-2.0.0-beta.1-arm64.dmg")
        let plan = try ws.scan()
        #expect(plan.item(stable)?.status == .keep)
        #expect(plan.item(newPreview)?.status == .keep)
        #expect(plan.item(oldPreview)?.status == .cleanup)
    }

    @Test func sameVersionWithDifferentContentIsKept() throws {
        let ws = try SweepWorkspace()
        ws.file("Package.swift", "package")
        let first = ws.package("Product-1.0.0-arm64.dmg", "first", folder: "release")
        let second = ws.package("Product-1.0.0-arm64.dmg", "second", folder: "downloaded")
        let plan = try ws.scan()
        #expect(plan.item(first)?.status == .keep)
        #expect(plan.item(second)?.status == .keep)
        #expect(plan.item(first)?.reason.contains("不同内容") == true)
    }

    @Test func identicalCopyAndOlderVersionAreCleanup() throws {
        let ws = try SweepWorkspace()
        ws.file("Package.swift", "package")
        let old = ws.package("Product-0.9.0-arm64.dmg", "old")
        let keeper = ws.package("Product-1.0.0-arm64.dmg", "same")
        let duplicate = ws.package("Product-1.0.0-arm64.dmg", "same", folder: "downloaded")
        let plan = try ws.scan()
        let keeperID = try #require(plan.item(keeper)).id
        #expect(plan.item(keeper)?.status == .keep)
        // 内容完全一样的那份留不在下载目录里的。
        #expect(plan.item(duplicate)?.status == .cleanup)
        #expect(plan.item(duplicate)?.retainedIDs == [keeperID])
        #expect(plan.item(duplicate)?.snapshot?.contentSHA256 == plan.item(keeper)?.snapshot?.contentSHA256)
        #expect(plan.item(old)?.status == .cleanup)
        #expect(plan.item(old)?.retainedIDs == [keeperID])
    }

    @Test func installersInDifferentProjectsAreComparedSeparately() throws {
        let ws = try SweepWorkspace()
        ws.file("A/Package.swift", "")
        ws.file("B/Package.swift", "")
        let a = ws.package("Product-1.0.0-arm64.dmg", folder: "A/release")
        let b = ws.package("Product-2.0.0-arm64.dmg", folder: "B/release")
        let plan = try ws.scan()
        #expect(plan.item(a)?.status == .keep)
        #expect(plan.item(b)?.status == .keep)
    }

    @Test func unversionedInstallerNeedsReview() throws {
        let ws = try SweepWorkspace()
        let nameless = ws.package("1.2.3.dmg")
        let unversioned = ws.package("Installer.pkg")
        let plan = try ws.scan()
        #expect(plan.item(unversioned)?.status == .review)
        #expect(plan.item(unversioned)?.installer?.recognized == false)
        #expect(plan.item(nameless)?.status == .review)
        // 认不出来的不算内容摘要：那只在比较重复件时有用。
        #expect(plan.item(unversioned)?.snapshot?.contentSHA256 == nil)
    }

    // MARK: ZIP

    @Test func plainZipIsNotAnInstaller() throws {
        let ws = try SweepWorkspace()
        ws.package("Source-backup-1.0.0.zip", "source backup")
        ws.package("Source-backup-2.0.0.zip", "new source backup")
        ws.file("release/Design-1.0.0.zip", ZipBuilder.archive([
            .init(name: "mockups/home.png", content: Data("png".utf8)),
        ]))
        #expect(try ws.scan().items.isEmpty)
    }

    @Test func zipHoldingExactlyOneAppIsAnInstaller() throws {
        let ws = try SweepWorkspace()
        let plist = ZipBuilder.infoPlist(identifier: "test.product")
        let old = ws.file("release/Product-1.0.0-arm64.zip", ZipBuilder.archive([
            .init(name: "Product.app/Contents/Info.plist", content: plist),
            .init(name: "Product.app/Contents/MacOS/Product", content: Data("binary".utf8)),
        ]))
        let new = ws.file("release/Product-1.1.0-arm64.zip", ZipBuilder.archive([
            .init(name: "Product.app/Contents/MacOS/Product", content: Data("binary 2".utf8), deflate: true),
            .init(name: "Product.app/Contents/Info.plist", content: plist, deflate: true),
        ]))
        let plan = try ws.scan()
        #expect(plan.item(old)?.status == .cleanup)
        #expect(plan.item(new)?.status == .keep)
        #expect(plan.item(new)?.installer?.format == "zip")
        #expect(plan.item(new)?.installer?.product == "product")
    }

    @Test func doubtfulZipsAreLeftAlone() throws {
        let ws = try SweepWorkspace()
        let plist = ZipBuilder.infoPlist(identifier: "test.product")
        // 两个 App、App 不在顶层、没有 bundle id、校验值不对、根本不是 ZIP：都不当安装包。
        let cases: [(String, Data)] = [
            ("Two-1.0.0.zip", ZipBuilder.archive([
                .init(name: "A.app/Contents/Info.plist", content: plist),
                .init(name: "B.app/Contents/Info.plist", content: plist),
            ])),
            ("Nested-1.0.0.zip", ZipBuilder.archive([
                .init(name: "backup/Old.app/Contents/Info.plist", content: plist),
            ])),
            ("Anonymous-1.0.0.zip", ZipBuilder.archive([
                .init(name: "X.app/Contents/Info.plist", content: ZipBuilder.infoPlist(identifier: nil)),
            ])),
            ("Corrupt-1.0.0.zip", ZipBuilder.archive([
                .init(name: "X.app/Contents/Info.plist", content: plist, deflate: true, corruptCRC: true),
            ])),
            ("NotPlist-1.0.0.zip", ZipBuilder.archive([
                .init(name: "X.app/Contents/Info.plist", content: Data("[1, 2, 3]".utf8)),
            ])),
            ("Truncated-1.0.0.zip", ZipBuilder.archive([
                .init(name: "X.app/Contents/Info.plist", content: plist),
            ]).dropLast(30)),
            ("Empty-1.0.0.zip", Data()),
        ]
        for (name, data) in cases {
            ws.file("release/" + name, Data(data))
        }
        #expect(try ws.scan().items.isEmpty)
    }

    @Test func zipWithLeadingDataIsStillRead() throws {
        let ws = try SweepWorkspace()
        // 自解压程序这类文件，压缩包前面垫着别的数据。
        let archive = ZipBuilder.archive([
            .init(name: "Product.app/Contents/Info.plist", content: ZipBuilder.infoPlist(identifier: "test.product")),
        ])
        let path = ws.file("release/Product-3.0.0.zip", Data(repeating: 0x23, count: 512) + archive)
        #expect(SweepZip.soleAppInfo(ws.path(path))?["CFBundleIdentifier"] as? String == "test.product")
    }

    @Test func zip64ArchivesAreRead() throws {
        let ws = try SweepWorkspace()
        // 文件数超过 65535 或体积超过 4 GB 的压缩包用的是 ZIP64 的记录。
        let members: [ZipBuilder.Member] = [
            .init(name: "Product.app/Contents/MacOS/Product", content: Data("binary".utf8), deflate: true),
            .init(name: "Product.app/Contents/Info.plist", content: ZipBuilder.infoPlist(identifier: "test.zip64"), deflate: true),
        ]
        let path = ws.file("release/Product-4.0.0.zip", ZipBuilder.archive(members, zip64: true))
        #expect(SweepZip.soleAppInfo(ws.path(path))?["CFBundleIdentifier"] as? String == "test.zip64")
        #expect(try ws.scan().item(path)?.installer?.recognized == true)

        // ZIP64 的定位记录被截掉一截：读不懂，就不当安装包。
        var broken = ZipBuilder.archive(members, zip64: true)
        broken.removeSubrange((broken.count - 22 - 20)..<(broken.count - 22 - 10))
        let damaged = ws.file("release/Product-5.0.0.zip", broken)
        #expect(SweepZip.soleAppInfo(ws.path(damaged)) == nil)
    }

    @Test func appZipIsRecognizedByNameWithoutOpeningIt() throws {
        let ws = try SweepWorkspace()
        let old = ws.package("Product-1.0.0.app.zip", "not really a zip")
        let new = ws.package("Product-1.1.0.app.zip", "not really a zip either")
        let plan = try ws.scan()
        #expect(plan.item(old)?.status == .cleanup)
        #expect(plan.item(new)?.installer?.format == "app.zip")
    }

    // MARK: 应用包

    @Test func bundlesAreIdentifiedByInfoPlist() throws {
        let ws = try SweepWorkspace()
        ws.file("Package.swift", "package")
        let old = ws.app("copy-1.0.0/Product.app", identifier: "test.product", version: "1.0.0")
        let new = ws.app("copy-1.1.0/Product.app", identifier: "test.product", version: "1.1.0")
        let plan = try ws.scan()
        #expect(plan.item(old)?.status == .cleanup)
        #expect(plan.item(new)?.status == .keep)
        let metadata = try #require(plan.item(new)?.installer)
        #expect(metadata.product == "test.product")
        #expect(metadata.architecture == "arm64")
        #expect(metadata.format == "app")
        #expect(plan.item(new)?.snapshot?.kind == "directory")
        // 应用包整个算一项，不会再往里找。
        #expect(plan.items.count == 2)
    }

    @Test func bundleWithoutUsableIdentityNeedsReview() throws {
        let ws = try SweepWorkspace()
        let vague = ws.app("Vague.app", identifier: "test.vague", version: "2")
        ws.dir("Hollow.app/Contents")
        let plan = try ws.scan()
        #expect(plan.item(vague)?.status == .review)
        #expect(plan.item(vague)?.installer?.recognized == false)
        // 连 Info.plist 都没有的 .app 目录不是候选项。
        #expect(plan.item("Hollow.app") == nil)
    }

    // MARK: 版本号解析

    @Test func versionParsing() throws {
        func rank(_ text: String) -> [Int]? { SweepRecognizer.findVersion(text)?.version.rank }
        #expect(rank("Product-1.9.0-arm64") == [1, 9, 0, 5, 0])
        #expect(rank("v2.0.10") == [2, 0, 10, 5, 0])
        #expect(rank("App_3.1.4-RC2") == [3, 1, 4, 4, 2])
        #expect(rank("App-3.1.4.beta") == [3, 1, 4, 3, 0])
        #expect(rank("App-3.1.4-dev.12") == [3, 1, 4, 0, 12])
        #expect(rank("App-1.2") == nil)
        #expect(rank("App") == nil)
        #expect(rank("App-99999999999999999999.0.0") == nil)
        let preview = try #require(SweepRecognizer.findVersion("App-3.1.4-rc.2-arm64")?.version)
        #expect(preview.pre)
        #expect(preview.text == "3.1.4-rc.2")
        #expect(preview.base == [3, 1, 4])
    }

    @Test func productArchitectureAndVariantComeFromTheFileName() throws {
        let ws = try SweepWorkspace()
        func metadata(_ name: String) throws -> SweepInstaller {
            try #require(SweepRecognizer.installer(ws.path(ws.package(name)), isDirectory: false))
        }
        let plain = try metadata("My Tool-1.2.3-macos-aarch64.dmg")
        #expect(plain.product == "my tool")
        #expect(plain.architecture == "arm64")
        #expect(plain.format == "dmg")

        let variant = try metadata("Tool_2.0.0_x64-setup.exe")
        #expect(variant.product == "tool/setup")
        #expect(variant.architecture == "x86_64")

        #expect(try metadata("Tool-1.0.0-universal.pkg").architecture == "universal")
        #expect(try metadata("Tool-1.0.0.pkg").architecture == "unknown")
        #expect(SweepRecognizer.installer(ws.path(ws.package("notes-1.0.0.txt")), isDirectory: false) == nil)
    }
}
