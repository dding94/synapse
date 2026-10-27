import Foundation

// v0.9 볼트 감지 (docs/V09.md §3.2). 출처가 볼트가 아니어도(데스크톱 출처 안의 볼트, 볼트 안 폴더만 따로 연결) 절대 경로로 PARA 위치를 읽는다.
// 볼트 = .obsidian 폴더가 있는 폴더. 켜진 로컬 출처마다 루트 자신 · 조상(홈 폴더 아래까지) · 아래 2단계에서 찾는다.

struct VaultMap: Equatable {
    /// 볼트 루트 절대 경로(실제 경로·NFC, 끝 "/" 없음). 긴 것 먼저(안쪽 볼트 우선).
    let roots: [String]

    static let empty = VaultMap(roots: [])

    static func detect(sources: [SourceConfig], home: String = NSHomeDirectory()) -> VaultMap {
        let homeRoot = Indexer.nfc(Indexer.realPath(home))
        var found = Set<String>()
        for s in sources where s.enabled && (s.kind == .folder || s.kind == .obsidian) {
            guard let raw = s.path, !raw.isEmpty else { continue }
            let root = Indexer.nfc(Indexer.realPath(raw))
            if isVault(root) { found.insert(root) }
            var p = (root as NSString).deletingLastPathComponent
            while p.count > homeRoot.count && p.hasPrefix(homeRoot + "/") {
                if isVault(p) { found.insert(p); break }
                p = (p as NSString).deletingLastPathComponent
            }
            for c in children(root) {
                if isVault(c) { found.insert(c) }
                for g in children(c) where isVault(g) { found.insert(g) }
            }
        }
        return VaultMap(roots: found.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
    }

    static func isVault(_ dir: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir + "/.obsidian", isDirectory: &d) && d.boolValue
    }

    /// 바로 아래 폴더(숨김·건너뛰는 이름 제외, 심볼릭 링크 따라가지 않음).
    private static func children(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [String] = []
        for n in names where !Indexer.isSkippedDirName(n) {
            let p = dir + "/" + n
            guard let a = try? fm.attributesOfItem(atPath: p), (a[.type] as? FileAttributeType) == .typeDirectory else { continue }
            out.append(Indexer.nfc(p))
        }
        return out
    }

    /// 이 경로를 담은 볼트 루트 (가장 안쪽).
    func vault(forAbs path: String) -> String? {
        let p = Indexer.nfc(path)
        return roots.first { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// 볼트 기준 상대 경로 (볼트 루트 자신이면 ""). 볼트 밖이면 nil.
    func paraRel(forAbs path: String) -> String? {
        guard let r = vault(forAbs: path) else { return nil }
        let p = Indexer.nfc(path)
        return p == r ? "" : String(p.dropFirst(r.count + 1))
    }
}
