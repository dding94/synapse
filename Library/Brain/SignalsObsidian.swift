import Foundation
import AppKit

// 옵시디언 최근 파일 (§4.4). workspace.json은 읽기만 하고, 형식이 다르면 조용히 건너뛴다.

extension Signals {
    private func workspaceFile(_ root: URL) -> URL { root.appendingPathComponent(".obsidian/workspace.json") }

    private func readLastOpen(_ url: URL) -> [String]? {
        guard let d = FileManager.default.contents(atPath: url.path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = o["lastOpenFiles"] as? [String] else { return nil }
        return list.map { $0.precomposedStringWithCanonicalMapping }
    }

    /// main 영역(편집 탭·분할 화면) leaf들의 열린 파일. 사이드바(left·right)는 보지 않는다. 형식이 다르면 [].
    func mainLeafFiles(_ url: URL) -> [String] {
        guard let d = FileManager.default.contents(atPath: url.path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let main = o["main"] as? [String: Any] else { return [] }
        var out: [String] = []
        func walk(_ node: [String: Any], depth: Int) {
            guard depth < 32 else { return }
            if node["type"] as? String == "leaf", let st = node["state"] as? [String: Any] {
                // 옵시디언 형식: state.state.file (옛·다른 형식: state.file)
                let file = ((st["state"] as? [String: Any])?["file"] as? String) ?? (st["file"] as? String)
                if let f = file, !f.isEmpty { out.append(f.precomposedStringWithCanonicalMapping) }
            }
            for c in node["children"] as? [[String: Any]] ?? [] { walk(c, depth: depth + 1) }
        }
        walk(main, depth: 0)
        return out
    }

    /// 앱 모드 20초 타이머. workspace.json이 바뀌었으면 앞으로 올라온 항목을 "열림"으로 기록한다.
    /// 처음 본 목록은 기준으로만 삼는다.
    @discardableResult
    func checkObsidian() -> Int {
        var opened = 0
        for (src, root) in ctx.localRoots() where src.kind == .obsidian {
            let url = workspaceFile(root)
            guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mt = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            if obsidianStamps[src.id] == mt { continue }
            guard let list = readLastOpen(url) else { obsidianStamps[src.id] = mt; continue }
            let first = obsidianStamps[src.id] == nil
            let prev = obsidianLists[src.id] ?? []
            obsidianStamps[src.id] = mt; obsidianLists[src.id] = list
            if first { continue }
            for (i, rel) in list.enumerated() {
                if let j = prev.firstIndex(of: rel), j <= i { continue }
                guard let d = ctx.doc(id: src.id + ":" + rel) else { continue }
                insertActivity(ts: mt, docId: d.id, path: d.absPath, kind: "opened", actor: .human, origin: "obsidian",
                               session: nil, detail: nil)
                _ = try? db.run("""
                UPDATE doc_state SET last_open=MAX(COALESCE(last_open,0), ?), last_human=MAX(COALESCE(last_human,0), ?) WHERE doc_id=?
                """, [.double(mt), .double(mt), .text(d.id)])
                opened += 1
            }
        }
        return opened
    }

    /// 옵시디언이 실행 중이면 볼트마다 최근 연 파일 상위 3개 + 지금 열린 탭·분할 화면 파일의 절대 경로.
    func obsidianOpenPaths() -> [String] {
        let running = ctx.env.obsidianRunning
            ?? NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "md.obsidian" }
        guard running else { return [] }
        var out: [String] = []
        var seenRoots = Set<String>()
        for (src, root) in ctx.localRoots() where src.kind == .obsidian {
            seenRoots.insert(Indexer.nfc(Indexer.realPath(root.path)))
            let url = workspaceFile(root)
            var rels: [String] = []
            for r in (readLastOpen(url) ?? []).prefix(3) + mainLeafFiles(url) where !rels.contains(r) { rels.append(r) }
            // 색인 문서가 있으면 그 절대 경로(출처 경로와 색인 경로의 /private 차이를 피한다)
            out += rels.map { rel in
                ctx.doc(id: src.id + ":" + rel)?.absPath ?? root.appendingPathComponent(rel).path.precomposedStringWithCanonicalMapping
            }
        }
        // v0.9: 출처가 아닌 볼트(데스크톱 출처 안의 볼트처럼 VaultMap으로 찾은 것)도 같은 방식으로 본다
        for v in ctx.vaults.roots where !seenRoots.contains(v) {
            seenRoots.insert(v)
            let url = workspaceFile(URL(fileURLWithPath: v))
            var rels: [String] = []
            for r in (readLastOpen(url) ?? []).prefix(3) + mainLeafFiles(url) where !rels.contains(r) { rels.append(r) }
            for rel in rels {
                let abs = Indexer.nfc(v + "/" + rel)
                let p = ctx.doc(path: abs)?.absPath ?? abs
                if !out.contains(p) { out.append(p) }
            }
        }
        return out
    }
}
