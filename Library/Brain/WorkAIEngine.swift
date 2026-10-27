import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// §5.9 기기 AI. 규칙 대체가 바닥이고, Apple Intelligence가 켜져 있을 때만 요약·이유 문장을 보탠다.
// Xcode 없이 빌드하므로 @Generable 매크로는 쓰지 않고 LanguageModelSession.respond(to:)의 문자열 응답만 쓴다.

protocol EnrichEngine {
    var id: String { get }
    /// (상태 "ready"|"off"|"unsupported", 사람이 읽는 이유)
    func state() -> (String, String?)
    func run(task: String, input: String, maxChars: Int) async throws -> String
}

enum WorkEngineError: Error { case unavailable }

/// 규칙 엔진(항상): summary는 규칙 대체, reason은 칩 문구를 잇는다.
final class WorkRulesEngine: EnrichEngine {
    let id = "rules"
    func state() -> (String, String?) { ("ready", nil) }
    func run(task: String, input: String, maxChars: Int) async throws -> String {
        if task == "summary" { return WorkRules.summary(markdown: input, maxChars: maxChars)?.text ?? "" }
        let parts = input.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return WorkUtil.prefix(parts.joined(separator: " · "), maxChars)
    }
}

/// SystemLanguageModel.availability → (state, reason). 시험할 수 있게 문자열 코드로 받는다.
enum WorkAppleState {
    static func map(_ code: String) -> (String, String?) {
        switch code {
        case "available": return ("ready", nil)
        case "appleIntelligenceNotEnabled": return ("off", "Apple Intelligence가 꺼져 있어요")
        case "modelNotReady": return ("off", "모델을 내려받는 중이에요")
        case "deviceNotEligible": return ("unsupported", "이 Mac은 기기 AI를 지원하지 않아요")
        case "osTooOld": return ("unsupported", "macOS 26 이상에서 쓸 수 있어요")
        default: return ("unsupported", "기기 AI를 쓸 수 없어요")
        }
    }
}

final class WorkAppleEngine: EnrichEngine {
    let id = "apple"
    static func make() -> EnrichEngine { WorkAppleEngine() }

    func availabilityCode() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return WorkAppleBridge.code() }
        #endif
        return "osTooOld"
    }
    func state() -> (String, String?) { WorkAppleState.map(availabilityCode()) }

    func run(task: String, input: String, maxChars: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return try await WorkAppleBridge.respond(task: task, input: input, maxChars: maxChars) }
        #endif
        throw WorkEngineError.unavailable
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum WorkAppleBridge {
    static func code() -> String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let r):
            switch r {
            case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
            case .modelNotReady: return "modelNotReady"
            case .deviceNotEligible: return "deviceNotEligible"
            @unknown default: return "unknown"
            }
        }
    }

    static func respond(task: String, input: String, maxChars: Int) async throws -> String {
        let instructions = task == "summary"
            ? "너는 문서 사서다. 주어진 문서를 한국어 한 줄(\(maxChars)자 이하)로 요약한다. 문서에 있는 단어만 쓰고, 새 사실을 지어내지 않는다. 요약 문장 하나만 답한다."
            : "주어진 근거 칩들을 한국어 한 문장(\(maxChars)자 이하)으로 잇는다. 칩에 없는 사실을 더하지 않는다. 문장 하나만 답한다."
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: input)
        return response.content
    }
}
#endif

/// 기기 AI 출력 검증 (§5.9): 한 줄·길이·원문 토큰 60%.
enum WorkValidator {
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) } else { if cur.count >= 2 { out.append(cur) }; cur = "" }
        }
        if cur.count >= 2 { out.append(cur) }
        return out
    }
    /// 출력의 2글자 이상 토큰 중 ratio 이상이 원문에 있는가 (조사를 뗀 형태도 인정).
    static func grounded(_ output: String, source: String, ratio: Double = 0.6) -> Bool {
        let toks = tokens(output)
        guard !toks.isEmpty else { return false }
        let src = source.lowercased()
        let hit = toks.filter { src.contains($0) || src.contains(Korean.stripJosa($0)) }.count
        return Double(hit) / Double(toks.count) >= ratio
    }
    /// 한 줄로 다듬어 길이를 본다. 넘거나 비면 nil.
    static func clean(_ output: String, maxChars: Int) -> String? {
        var t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { t = String(t[..<nl]) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespaces))
        if t.hasPrefix("요약:") { t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, t.count <= maxChars else { return nil }
        return t
    }
    static func summary(_ output: String, source: String, maxChars: Int = 80) -> String? {
        guard let t = clean(output, maxChars: maxChars), grounded(t, source: source, ratio: 0.6) else { return nil }
        return t
    }
    static func reason(_ output: String, chips: String, maxChars: Int = 60) -> String? {
        guard let t = clean(output, maxChars: maxChars), grounded(t, source: chips, ratio: 0.3) else { return nil }
        return t
    }
}

/// 규칙 요약 (§5.9 규칙 대체): 요약·TL;DR·결론·결정 제목 아래 첫 문장 → section, 없으면 첫 문단 첫 문장 → first.
enum WorkRules {
    static let summaryHeads = ["요약", "tl;dr", "tldr", "결론", "결정"]

    static func stripListMarker(_ l: String) -> String {
        var t = l.trimmingCharacters(in: .whitespaces)
        for p in ["> ", ">"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        if let r = t.range(of: #"^(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) { t = String(t[r.upperBound...]) }
        if let r = t.range(of: #"^\[[ xX/\-]\]\s+"#, options: .regularExpression) { t = String(t[r.upperBound...]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func inline(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!?\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"!?\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func firstSentence(_ p: String, maxChars: Int) -> String {
        let chars = Array(p)
        var end = chars.count
        for i in chars.indices where ".?!。".contains(chars[i]) {
            if i + 1 == chars.count || chars[i + 1].isWhitespace { end = i + 1; break }
        }
        let s = String(chars[..<end]).trimmingCharacters(in: .whitespaces)
        return s.count <= maxChars ? s : String(s.prefix(maxChars - 1)) + "…"
    }

    static func isHeading(_ l: String) -> String? {
        guard let r = l.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) else { return nil }
        return String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    /// 본문 줄로 볼 수 있는가 (표·가로선·태그만 있는 줄·그림 제외).
    static func contentLine(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("|") || t.hasPrefix("![") || t.range(of: #"^[-*_=]{3,}$"#, options: .regularExpression) != nil { return nil }
        let words = t.split(separator: " ")
        if !words.isEmpty && words.allSatisfy({ $0.hasPrefix("#") }) { return nil }
        let s = inline(stripListMarker(t))
        return s.isEmpty ? nil : s
    }

    static func summary(markdown: String, maxChars: Int = 80) -> (text: String, source: String)? {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(end + 1)...])
        }
        var inCode = false, underSummary = false, para: [String] = []
        var first: String? = nil
        func flush() -> String? {
            defer { para = [] }
            return para.isEmpty ? nil : firstSentence(para.joined(separator: " "), maxChars: maxChars)
        }
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            if let h = isHeading(l) {
                if underSummary, let s = flush() { return (s, "section") }
                if first == nil, let s = flush() { first = s }
                let low = h.lowercased()
                underSummary = summaryHeads.contains { low.contains($0) }
                continue
            }
            // 문단 경계: 요약 절이면 끝, 아니면 첫 문단으로 기억
            func boundary() -> String? {
                if underSummary { return flush() }
                if first == nil { first = flush() } else { para = [] }
                return nil
            }
            if let c = contentLine(l) {
                let isList = l.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
                if isList && !para.isEmpty, let s = boundary() { return (s, "section") }
                para.append(c)
                if isList || c.contains(where: { ".?!。".contains($0) }), let s = boundary() { return (s, "section") }
            } else if !para.isEmpty, let s = boundary() { return (s, "section") }
        }
        if underSummary, let s = flush() { return (s, "section") }
        if first == nil { first = flush() }
        return first.map { ($0, "first") }
    }
}
