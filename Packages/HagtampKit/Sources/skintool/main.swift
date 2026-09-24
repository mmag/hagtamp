import Foundation
import SkinKit
import SkinRenderer

/// Developer tool for skin loading and rendering.
///
///     skintool info <skin>
///     skintool render <skin> <out.png> [scale]
///     skintool compare <corpus-dir> [out-dir]
///
/// `compare` renders every skin of a corpus fetched by
/// scripts/fetch_skin_corpus.py in the Skin Museum screenshot state and diffs
/// it against the museum screenshot.

let usage = """
    usage: skintool info <skin>
           skintool render <skin> <out.png> [scale]
           skintool compare <corpus-dir> [out-dir]
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Skins where the museum screenshot is wrong because of a Webamp bug and we
/// deliberately follow Winamp instead.
let webampBugs: [String: String] = [
    "c9f9d6c70316e9958f0b339a222f4bd9":
        "region.txt `NumPoints=8 ;comment`: Webamp drops the region, Winamp reads 8 (atoi)",
    "03a967351bc69b83a3c063782997d434":
        "region.txt hole polygons: Webamp unions polygons, Winamp builds one poly-polygon region",
]

func compare(corpus: URL, output: URL?) throws {
    let skinsDir = corpus.appendingPathComponent("skins")
    let shotsDir = corpus.appendingPathComponent("screenshots")
    var names: [String: String] = [:]
    if let data = try? Data(contentsOf: corpus.appendingPathComponent("manifest.json")),
        let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
    {
        for entry in manifest { names[entry["md5"] ?? ""] = entry["filename"] }
    }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

    let areas: [(String, PixelRect)] = [
        ("main", PixelRect(x: 0, y: 0, width: 275, height: 116)),
        ("eq", PixelRect(x: 0, y: 116, width: 275, height: 116)),
        ("playlist", PixelRect(x: 0, y: 232, width: 275, height: 116)),
    ]
    var results: [(md5: String, diff: ImageDiff)] = []
    var failures: [String] = []

    let files = try FileManager.default.contentsOfDirectory(atPath: skinsDir.path).filter { $0.hasSuffix(".wsz") }.sorted()
    for file in files {
        let md5 = String(file.dropLast(4))
        let label = names[md5] ?? md5
        guard let reference = Bitmap(contentsOf: shotsDir.appendingPathComponent("\(md5).png")) else {
            failures.append("\(label): no screenshot")
            continue
        }
        guard reference.width == ReferenceScene.width, reference.height == ReferenceScene.height else {
            failures.append("\(label): screenshot is \(reference.width)x\(reference.height)")
            continue
        }
        let skin: Skin
        do {
            skin = try Skin.load(contentsOf: skinsDir.appendingPathComponent(file))
        } catch {
            failures.append("\(label): \(error)")
            continue
        }
        let diff = ImageDiff(
            reference: reference, render: ReferenceScene.render(skin), areas: areas,
            ignoring: ReferenceScene.volatileRects)
        results.append((md5, diff))
        if let output, diff.totalMismatches > 0 {
            try diff.visualization.scaled(by: 2).pngData().write(to: output.appendingPathComponent("\(md5).png"))
        }
    }

    results.sort { $0.diff.totalMismatches > $1.diff.totalMismatches }
    print("mismatching pixels per window (main / eq / playlist), worst first:")
    for (md5, diff) in results where diff.totalMismatches > 0 && webampBugs[md5] == nil {
        let counts = diff.areas.map { String(format: "%6d", $0.mismatches) }.joined(separator: " ")
        print("\(counts)  \(md5)  \(names[md5] ?? "")")
    }
    let known = results.filter { webampBugs[$0.md5] != nil }
    for (md5, diff) in known where diff.totalMismatches > 0 {
        print("known Webamp bug (\(diff.totalMismatches) px): \(md5): \(webampBugs[md5]!)")
    }
    let judged = results.filter { webampBugs[$0.md5] == nil }
    for (index, area) in areas.enumerated() {
        let perfect = judged.filter { $0.diff.areas[index].mismatches == 0 }.count
        print("\(area.0): \(perfect)/\(judged.count) pixel-perfect")
    }
    for failure in failures { print("failed: \(failure)") }
}

// Dispatch last: globals in main.swift are initialised in order, so everything
// above must exist before a command runs.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }

switch command {
case "info":
    guard arguments.count == 2 else { fail(usage) }
    let skin = try Skin.load(contentsOf: URL(fileURLWithPath: arguments[1]))
    print("name: \(skin.name)")
    print("sheets: \(skin.sheets.keys.map(\.rawValue).sorted().joined(separator: " "))")
    print("nums_ex: \(skin.usesNumsEx)")
    print("playlist: \(skin.playlistStyle)")
    print("viscolors: \(skin.visColors.map(\.description).joined(separator: " "))")
    let regions = skin.regions
    print("regions: main=\(regions.main?.count ?? 0) shade=\(regions.mainShade?.count ?? 0) eq=\(regions.equalizer?.count ?? 0) eqshade=\(regions.equalizerShade?.count ?? 0)")
    for warning in skin.warnings { print("warning: \(warning)") }

case "render":
    guard arguments.count >= 3 else { fail(usage) }
    let skin = try Skin.load(contentsOf: URL(fileURLWithPath: arguments[1]))
    let scale = arguments.count > 3 ? Int(arguments[3]) ?? 1 : 1
    try ReferenceScene.render(skin).scaled(by: scale).pngData().write(to: URL(fileURLWithPath: arguments[2]))

case "compare":
    guard arguments.count >= 2 else { fail(usage) }
    try compare(corpus: URL(fileURLWithPath: arguments[1]), output: arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil)

default:
    fail(usage)
}
