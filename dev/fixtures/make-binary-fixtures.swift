#!/usr/bin/env swift
// 이진 형식 테스트 자료(pdf·docx·rtf·hwpx)를 만든다. 내용은 모두 가상이다.
// 사용: swift dev/fixtures/make-binary-fixtures.swift   (프로젝트 루트나 어디서든 — 스크립트 위치 기준)
import Foundation
import AppKit
import CoreText
import CoreGraphics

let fm = FileManager.default
let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let root = fm.fileExists(atPath: here.appendingPathComponent("업무문서").path) ? here : URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("dev/fixtures")
let formatDir = root.appendingPathComponent("업무문서/형식")
let attachDir = root.appendingPathComponent("테스트볼트/첨부")
try fm.createDirectory(at: formatDir, withIntermediateDirectories: true)
try fm.createDirectory(at: attachDir, withIntermediateDirectories: true)

// MARK: PDF (CoreText로 한글을 그려 글자 정보가 살아 있는 PDF)

func makePDF(at url: URL, title: String, pages: [[String]]) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)    // A4
    let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Synapse fixtures"]
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { fatalError("pdf 생성 실패") }
    let body = CTFontCreateWithName("Apple SD Gothic Neo" as CFString, 13, nil)
    let head = CTFontCreateWithName("Apple SD Gothic Neo Bold" as CFString, 20, nil)
    for lines in pages {
        ctx.beginPDFPage(nil)
        var y: CGFloat = 780
        for (i, line) in lines.enumerated() {
            let isHead = i == 0
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): isHead ? head : body,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.textPosition = CGPoint(x: 56, y: y)
            CTLineDraw(ctLine, ctx)
            y -= isHead ? 40 : 24
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

makePDF(at: formatDir.appendingPathComponent("정산 보고서.pdf"), title: "2026년 3분기 정산 보고서", pages: [
    ["3분기 정산 보고서",
     "작성: 재무운영팀 / 검토: 이영희",
     "정산 대시보드의 월별 숫자와 결제 원장의 합계가 0.3% 어긋나는 문제를 조사했다.",
     "원인은 환불 반영 시점이다. 환불이 승인된 날이 아니라 접수된 날에 차감되고 있었다.",
     "관련 이슈: PAY-150 (환불 차감 기준일 통일).",
     "9월 말 기준 미정산 금액은 가상의 수치로 1,240만 원이다."],
    ["다음 단계",
     "첫째, 정산 배치에서 환불 승인일을 기준으로 차감하도록 고친다.",
     "둘째, 환불 절차 문서를 고객 응대팀과 함께 갱신한다.",
     "셋째, 정산 대시보드에 환불 보류 건수를 따로 보여 준다.",
     "PAY-150 이 닫히면 4분기 정산부터 새 기준을 적용한다."],
])
makePDF(at: attachDir.appendingPathComponent("아키텍처.pdf"), title: "Synapse 아키텍처 개요", pages: [
    ["Synapse 아키텍처 개요",
     "자료는 원래 자리에서 읽고 이 Mac 안의 SQLite 색인에만 저장한다.",
     "추출기가 본문을 읽고, 색인기가 조사와 초성을 처리해 전문 검색 색인을 만든다.",
     "관계 계산기는 링크, 태그, 공통 키워드, 같은 폴더로 문서를 잇는다.",
     "화면은 그래프와 검색 두 가지 진입점을 가진다."],
    ["보안 메모",
     "토큰은 키체인에만 두고, 외부로 나가는 요청은 연결한 Atlassian 사이트뿐이다."],
])

// MARK: DOCX · RTF (NSAttributedString)

func richDocument() -> NSAttributedString {
    let result = NSMutableAttributedString()
    func add(_ s: String, size: CGFloat, bold: Bool) {
        let font = NSFont(name: bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
        result.append(NSAttributedString(string: s + "\n", attributes: [.font: font]))
    }
    add("환불 절차", size: 20, bold: true)
    add("고객이 환불을 요청하면 접수, 확인, 승인, 지급 순서로 처리한다.", size: 13, bold: false)
    add("1. 접수: 고객 응대팀이 주문 번호와 사유를 기록한다.", size: 13, bold: false)
    add("2. 확인: 결제 수단과 정산 상태를 확인한다. 이미 정산된 건은 정산팀에 알린다.", size: 13, bold: false)
    add("3. 승인: 50만 원 이하는 팀장이, 초과는 재무운영팀이 승인한다.", size: 13, bold: false)
    add("4. 지급: 승인일 기준 영업일 3일 안에 원 결제 수단으로 돌려준다. 관련 이슈 PAY-150.", size: 13, bold: false)
    return result
}
let doc = richDocument()
let full = NSRange(location: 0, length: doc.length)
let docx = try doc.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML,
                                                          .title: "환불 절차"])
try docx.write(to: formatDir.appendingPathComponent("환불 절차.docx"))

let summary = NSMutableAttributedString(string: "환불 절차 요약\n", attributes: [.font: NSFont(name: "AppleSDGothicNeo-Bold", size: 18)!])
summary.append(NSAttributedString(string: "접수 후 확인과 승인을 거쳐 영업일 3일 안에 지급한다.\n정산이 끝난 건은 정산팀에 먼저 알린다. 기준일 논의는 PAY-150 에서 진행 중이다.\n",
                                  attributes: [.font: NSFont(name: "AppleSDGothicNeo-Regular", size: 12)!]))
let rtf = try summary.data(from: NSRange(location: 0, length: summary.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
try rtf.write(to: formatDir.appendingPathComponent("환불 절차 요약.rtf"))

// MARK: HWPX (zip: mimetype을 압축 없이 맨 앞에)

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func makeHWPX(at url: URL, title: String, paragraphs: [String]) throws {
    let work = fm.temporaryDirectory.appendingPathComponent("hwpx-\(UUID().uuidString)")
    try fm.createDirectory(at: work.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try fm.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    func put(_ rel: String, _ s: String) throws { try s.write(to: work.appendingPathComponent(rel), atomically: true, encoding: .utf8) }
    // mimetype 끝에 줄바꿈이 없어야 한다
    try "application/hwp+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
    try put("version.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version" targetApplication="WORDPROCESSOR" major="5" minor="0" micro="5" buildNumber="0" os="1" xmlVersion="1.2"/>"#)
    try put("META-INF/container.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container"><ocf:rootfiles><ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/></ocf:rootfiles></ocf:container>"#)
    try put("Contents/content.hpf", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <opf:package xmlns:opf="http://www.idpf.org/2007/opf/" version="" unique-identifier="" id="">
      <opf:metadata><opf:title>\(xmlEscape(title))</opf:title><opf:language>ko</opf:language></opf:metadata>
      <opf:manifest><opf:item id="header" href="Contents/header.xml" media-type="application/xml"/><opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/></opf:manifest>
      <opf:spine><opf:itemref idref="header" linear="yes"/><opf:itemref idref="section0" linear="yes"/></opf:spine>
    </opf:package>
    """)
    try put("Contents/header.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" version="1.2" secCnt="1"/>"#)
    let paras = paragraphs.enumerated().map { i, p in
        #"<hp:p id="\#(i)" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>\#(xmlEscape(p))</hp:t></hp:run></hp:p>"#
    }.joined(separator: "\n")
    try put("Contents/section0.xml", """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
    \(paras)
    </hs:sec>
    """)
    try? fm.removeItem(at: url)
    func zip(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = work
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { fatalError("zip 실패") }
    }
    try zip(["-X", "-0", url.path, "mimetype"])
    try zip(["-X", "-r", "-9", url.path, "version.xml", "META-INF", "Contents"])
}

try makeHWPX(at: formatDir.appendingPathComponent("고객 응대 기준.hwpx"), title: "고객 응대 기준", paragraphs: [
    "고객 응대 기준",
    "고객 문의는 접수 후 한 영업일 안에 첫 답변을 드린다.",
    "환불 문의는 환불 절차 문서에 따라 접수하고, 정산이 끝난 건은 정산팀에 먼저 알린다.",
    "결제 오류는 이슈 PAY-150 과 같이 번호를 붙여 추적하며 해결 전까지 고객에게 진행 상황을 공유한다.",
    "불만 고객에게는 사과를 먼저 하고, 해결 가능한 범위를 분명히 설명한다.",
])
print("만든 곳: \(formatDir.path), \(attachDir.path)")
