// Synapse 예시 데이터 (v0.1 Graph.html에서 옮김). 실제 파일 연결 전까지 사용하는 가상의 문서 20개.
// 형식: docs[].links 는 이 문서가 직접 연결한 문서 id(나가는 링크). 들어오는 링크(백링크)는 app.js가 계산한다.
// 주제 색상은 styles.css 의 --topic-<key> 토큰에 있다.
window.SYNAPSE_DATA = {
  topics: {
    finance: { label: "결제 · 정산" },
    search: { label: "검색 · 기술" },
    product: { label: "제품 · 고객" },
    idea: { label: "아이디어" },
  },
  synonyms: [
    ["검색","찾기","찾아","search"],
    ["아이디어","발상","생각","idea"],
    ["정산","입금","settlement"],
    ["환불","취소","refund"],
    ["결제","지불","payment"],
    ["고객","사용자","customer"],
    ["해지","이탈"],
    ["인덱스","색인","index"],
    ["연결","그래프","시냅스","synapse"],
    ["단축키","런처","shortcut"],
  ],
  docs: [
    {
      id: "f1", title: "정산 흐름 정리", short: "정산 흐름", topic: "finance", kind: "설계 노트",
      path: "예시 공간 / 결제 / 정산 흐름 정리.md", updated: "2026-10-15",
      tags: ["정산","결제","매출"], links: ["f2","f3","f4","p3"],
      body: [
        "고객의 결제가 완료되면 주문의 상태와 결제 내역을 확인하고, 정산 대기 금액을 기록한다. 매출이 발생한 시점과 실제 입금되는 시점은 서로 다르다.",
        "일별 정산에서는 결제 금액에서 취소·환불 금액과 수수료를 차감한다. 거래 단위의 기록을 남겨야 숫자가 달라졌을 때 원인을 찾을 수 있다.",
        "연결해서 살펴볼 내용: 결제 상태 전이, 환불 예외 처리, 정산 대시보드. 고객에게 보이는 결제 상태와 운영자가 보는 정산 상태를 함께 검토한다.",
      ],
    },
    {
      id: "f2", title: "결제 상태 전이", short: "결제 상태 전이", topic: "finance", kind: "설계 노트",
      path: "예시 공간 / 결제 / 결제 상태 전이.md", updated: "2026-10-08",
      tags: ["결제","상태","정산"], links: ["f1","f3","f5"],
      body: [
        "결제는 준비, 승인 대기, 승인 완료, 취소라는 흐름을 가진다. 네트워크 응답이 늦어도 실제 승인 결과는 별도로 확인할 수 있어야 한다.",
        "같은 승인 요청이 여러 번 도착해도 주문은 한 번만 처리한다. 상태가 바뀔 때는 변경 시각과 원인을 남긴다.",
        "승인이 완료된 거래는 정산 대상이 된다. 취소 요청은 전액 취소인지 부분 환불인지 구분하고 최종 결제 금액을 다시 계산한다.",
      ],
    },
    {
      id: "f3", title: "환불 예외 처리 메모", short: "환불 예외 처리", topic: "finance", kind: "업무 메모",
      path: "예시 공간 / 결제 / 환불 예외 처리 메모.md", updated: "2026-09-27",
      tags: ["환불","취소","고객"], links: ["f2","p1","f4"],
      body: [
        "부분 환불 뒤 다시 환불을 요청하면 누적 환불 금액을 확인해야 한다. 이미 환불된 금액까지 취소하는 일이 없어야 한다.",
        "고객은 처리 상태보다 돈이 언제 돌아오는지를 궁금해한다. 안내 문구에는 요청 접수와 실제 환불 완료의 차이를 설명한다.",
        "정산이 끝난 뒤 발생한 환불은 다음 정산에서 조정한다. 상담 기록에서 반복되는 예외를 모아 안내 화면과 운영 절차를 개선한다.",
      ],
    },
    {
      id: "f4", title: "정산 대시보드 초안", short: "정산 대시보드", topic: "finance", kind: "화면 초안",
      path: "예시 공간 / 결제 / 정산 대시보드 초안.md", updated: "2026-10-03",
      tags: ["정산","대시보드","매출"], links: ["f1","p3","i4"],
      body: [
        "오늘 확인할 정산 예정액, 환불 조정액, 입금 완료액을 가장 먼저 보여준다. 각 숫자에서 해당 거래 목록으로 바로 이동할 수 있게 한다.",
        "요약 카드에는 기준 날짜와 집계 범위를 함께 표시한다. 같은 화면에서도 매출 기준과 입금 기준의 숫자가 다를 수 있기 때문이다.",
        "운영자가 이상한 숫자를 발견하면 관련 거래와 상담 기록을 연결해서 볼 수 있도록 구성한다. 정보의 연결이 숫자 확인 시간을 줄일 수 있는지 시험한다.",
      ],
    },
    {
      id: "f5", title: "중복 요청 방지 체크", short: "중복 요청 방지", topic: "finance", kind: "기술 메모",
      path: "예시 공간 / 결제 / 중복 요청 방지 체크.md", updated: "2026-09-11",
      tags: ["결제","중복","안정성"], links: ["f2","s3"],
      body: [
        "네트워크 재시도와 버튼 연속 클릭은 같은 요청을 반복해서 전달할 수 있다. 요청을 식별할 키를 정하고 처리 결과를 재사용한다.",
        "요청 키만 같고 내용이 다르면 정상적인 재시도로 취급하지 않는다. 승인 성공 이후 응답 전달이 실패한 경우도 별도로 살펴본다.",
        "결제뿐 아니라 검색 인덱스 갱신 작업에도 중복 처리 문제가 나타날 수 있다. 작업의 완료 여부를 기록하고 재실행 가능한 범위를 정리한다.",
      ],
    },
    {
      id: "s1", title: "로컬 검색 인덱스 설계", short: "로컬 검색 인덱스", topic: "search", kind: "설계 노트",
      path: "예시 공간 / 검색 / 로컬 검색 인덱스 설계.md", updated: "2026-10-16",
      tags: ["검색","인덱스","파일"], links: ["s2","s3","s4","i1"],
      body: [
        "폴더 안 문서에서 제목, 본문, 태그를 추출해 검색용 인덱스를 만든다. 원본 파일의 위치와 수정 시각을 함께 저장한다.",
        "처음에는 정확한 단어와 부분 문자열로 찾는 방식을 검토한다. 사용자가 어떤 말로 검색하는지 관찰한 뒤 필요한 동의어를 추가한다.",
        "검색 결과에는 일치한 본문 일부를 보여준다. 파일명이 기억나지 않더라도 문서 내용을 확인하면서 원하는 자료인지 판단할 수 있어야 한다.",
      ],
    },
    {
      id: "s2", title: "검색어 동의어 노트", short: "검색어 동의어", topic: "search", kind: "연구 메모",
      path: "예시 공간 / 검색 / 검색어 동의어 노트.md", updated: "2026-10-10",
      tags: ["검색","동의어","키워드"], links: ["s1","p2","i1"],
      body: [
        "같은 개념도 서로 다른 단어로 기억한다. 환불과 취소, 검색과 찾기, 아이디어와 발상처럼 실제로 함께 쓰는 표현을 정리한다.",
        "동의어는 완전히 같은 뜻을 보장하지 않는다. 원래 검색어가 직접 일치한 결과를 우선 보여주고, 확장한 단어로 찾은 결과에는 이유를 표시한다.",
        "한국어 문서에서는 띄어쓰기와 영문 약어도 영향을 준다. 작은 예시 데이터로 검색 경험을 검토하고 범위를 점진적으로 넓힌다.",
      ],
    },
    {
      id: "s3", title: "파일 변경 감지 메모", short: "파일 변경 감지", topic: "search", kind: "기술 메모",
      path: "예시 공간 / 검색 / 파일 변경 감지 메모.md", updated: "2026-09-20",
      tags: ["파일","인덱스","안정성"], links: ["s1","f5"],
      body: [
        "파일이 수정되면 해당 문서의 검색 정보만 갱신한다. 짧은 시간에 여러 번 바뀐 파일은 마지막 상태를 기준으로 읽는다.",
        "파일 이름 변경, 이동, 삭제를 각각 처리한다. 삭제된 파일이 검색 결과에 계속 남아 있지 않도록 확인한다.",
        "변경 감지가 중단된 동안 누락된 항목을 복구할 수 있어야 한다. 마지막 검사 시점과 파일의 수정 시각을 비교하는 보완 방법을 생각해 본다.",
      ],
    },
    {
      id: "s4", title: "문서 연결 그래프 실험", short: "문서 연결 그래프", topic: "search", kind: "실험 노트",
      path: "예시 공간 / 검색 / 문서 연결 그래프 실험.md", updated: "2026-10-19",
      tags: ["검색","그래프","연결"], links: ["i1","i2","s5"],
      body: [
        "문서를 작은 점으로, 문서 사이의 연결을 가는 선으로 표현한다. 전체 지도는 관심사가 어디에 모여 있는지 보여준다.",
        "문서에 직접 적힌 링크와 같은 태그를 공유하는 관계는 서로 구분한다. 지도에 선이 많아지면 선택한 문서와 가까운 관계만 강조한다.",
        "검색 결과를 지도와 함께 보여주고 같은 문서를 선택할 수 있게 한다. 원하는 자료를 빨리 여는 흐름과 주변 자료를 탐색하는 흐름을 모두 시험한다.",
      ],
    },
    {
      id: "s5", title: "검색 결과 순위 실험", short: "검색 결과 순위", topic: "search", kind: "실험 노트",
      path: "예시 공간 / 검색 / 검색 결과 순위 실험.md", updated: "2026-10-06",
      tags: ["검색","키워드","실험"], links: ["s1","s2","p2"],
      body: [
        "제목에 검색어가 들어 있는 문서, 태그가 일치하는 문서, 본문에서 언급한 문서를 서로 다른 점수로 비교한다.",
        "검색 결과마다 왜 표시되었는지 간단히 설명한다. 직접 일치와 동의어 일치를 구분하면 사용자가 예상 밖 결과를 이해하는 데 도움이 된다.",
        "검색 실험에서는 찾고자 한 문서가 상위 결과에 있는지 확인한다. 점수를 정교하게 만드는 것보다 실제 찾는 행동을 관찰하는 것이 먼저다.",
      ],
    },
    {
      id: "p1", title: "고객 인터뷰 발췌", short: "고객 인터뷰", topic: "product", kind: "인터뷰 노트",
      path: "예시 공간 / 제품 / 고객 인터뷰 발췌.md", updated: "2026-10-14",
      tags: ["고객","환불","불편"], links: ["p2","p4","f3"],
      body: [
        "예시 인터뷰: “전에 읽었던 안내가 어디 있었는지 기억이 안 나요. 검색하면 비슷한 제목이 너무 많이 나와요.”",
        "다른 고객은 환불 접수 이후 진행 상태를 알기 어렵다고 말했다. 필요한 정보는 안내 페이지와 상담 기록에 나뉘어 있었다.",
        "이번 인터뷰에서 얻은 가설은 정보의 양보다 다시 찾는 경로가 중요하다는 것이다. 검색 결과와 연결 문서가 어떤 도움을 주는지 살펴본다.",
      ],
    },
    {
      id: "p2", title: "제품 탐색 경험 개선", short: "탐색 경험 개선", topic: "product", kind: "제품 기획",
      path: "예시 공간 / 제품 / 제품 탐색 경험 개선.md", updated: "2026-10-18",
      tags: ["제품","검색","고객"], links: ["p1","s5","i3"],
      body: [
        "사용자가 원하는 문서를 찾는 흐름을 입력, 후보 확인, 미리보기, 열기로 나눈다. 각 단계에서 불필요한 선택을 줄인다.",
        "키보드로 후보를 오가고 본문 일부를 읽을 수 있게 한다. 검색어가 정확하지 않아도 다른 표현을 시도할 수 있도록 관련 키워드를 제안한다.",
        "연결 지도는 사용자가 이미 찾은 문서 주변을 탐색할 때 활용한다. 처음부터 복잡한 지도를 해석해야만 검색할 수 있게 만들지는 않는다.",
      ],
    },
    {
      id: "p3", title: "매출 지표 정의", short: "매출 지표 정의", topic: "product", kind: "업무 노트",
      path: "예시 공간 / 제품 / 매출 지표 정의.md", updated: "2026-09-16",
      tags: ["매출","정산","제품"], links: ["f1","f4","p5"],
      body: [
        "매출, 결제액, 정산액, 입금액은 서로 다른 숫자다. 화면을 만들기 전에 각 지표가 무엇을 포함하고 제외하는지 정리한다.",
        "취소와 환불의 반영 시점도 중요하다. 특정 기간에 발생한 거래를 볼 것인지, 그 기간에 입금된 금액을 볼 것인지 명확히 표시한다.",
        "지표 정의 문서는 대시보드 설계와 연결한다. 용어가 바뀌었을 때 영향을 받는 화면과 보고서를 함께 찾을 수 있도록 한다.",
      ],
    },
    {
      id: "p4", title: "고객 이탈 원인 가설", short: "이탈 원인 가설", topic: "product", kind: "가설 메모",
      path: "예시 공간 / 제품 / 고객 이탈 원인 가설.md", updated: "2026-09-05",
      tags: ["고객","해지","가설"], links: ["p1","p5","i5"],
      body: [
        "예시 가설: 기능이 없어서 떠나는 고객도 있지만, 필요한 기능과 정보를 찾지 못해 해지하는 고객도 있을 수 있다.",
        "상담과 인터뷰에서 반복되는 불편을 모으고 재방문 여부를 함께 살펴본다. 개별 사례만으로 전체 고객의 행동을 단정하지 않는다.",
        "검색 경험을 개선했을 때 문의와 이탈이 줄어드는지 작은 실험으로 확인한다. 관찰한 사실과 아직 검증하지 않은 가설은 구분해 기록한다.",
      ],
    },
    {
      id: "p5", title: "다음 제품 실험 목록", short: "다음 제품 실험", topic: "product", kind: "실험 목록",
      path: "예시 공간 / 제품 / 다음 제품 실험 목록.md", updated: "2026-09-30",
      tags: ["제품","실험","아이디어"], links: ["p2","p4","i3"],
      body: [
        "실험 1. 검색 결과에 일치한 본문을 함께 보여주면 원하는 문서를 더 빨리 고를 수 있을까?",
        "실험 2. 환불 안내에 다음 단계와 예상 처리 흐름을 보여주면 같은 문의가 반복되는 일을 줄일 수 있을까?",
        "실험 3. 관련 문서 세 개를 추천하면 이전에 놓쳤던 자료를 발견할 수 있을까? 각 실험은 작은 예시로 시작하고 반응을 관찰한다.",
      ],
    },
    {
      id: "i1", title: "연결형 검색 아이디어", short: "연결형 검색 아이디어", topic: "idea", kind: "아이디어 노트",
      path: "예시 공간 / 아이디어 / 연결형 검색 아이디어.md", updated: "2026-10-21",
      tags: ["아이디어","검색","연결"], links: ["s4","s1","i3","i2"],
      body: [
        "어떤 단어를 떠올리면 그 주변의 기억이 따라오는 것처럼, 키워드 하나에서 문서와 아이디어를 함께 찾는 공간을 상상한다.",
        "단축키를 누르면 조용한 검색 창이 나타난다. 왼쪽에서 문서를 고르고 오른쪽 지도에서 연결된 생각을 살펴본다. 하나를 발견하면 다음 문서로 자연스럽게 넘어간다.",
        "첫 실험은 예시 문서로 시작한다. 제목, 본문, 태그와 명시적인 문서 링크를 사용해 연결을 만들고, 실제 파일을 연결하기 전에 디자인과 조작감을 확인한다.",
      ],
    },
    {
      id: "i2", title: "디지털 정원 스케치", short: "디지털 정원", topic: "idea", kind: "스케치 메모",
      path: "예시 공간 / 아이디어 / 디지털 정원 스케치.md", updated: "2026-10-12",
      tags: ["아이디어","연결","기록"], links: ["i1","i5","s4"],
      body: [
        "메모를 한 번 쓰고 보관하는 대신 다른 생각과 이어지는 작은 정원으로 바라본다. 주제가 자라는 방향을 연결 지도로 볼 수 있으면 좋겠다.",
        "새 글을 많이 만드는 것만큼 기존 기록을 다시 읽고 연결하는 일이 중요하다. 우연히 발견한 오래된 메모가 지금의 문제에 실마리를 줄 수 있다.",
        "지도는 과하게 반짝이지 않게 한다. 어두운 배경, 작은 점, 얇은 선, 읽을 수 있는 제목만으로 생각의 구조를 드러낸다.",
      ],
    },
    {
      id: "i3", title: "단축키 런처 스케치", short: "단축키 런처", topic: "idea", kind: "화면 스케치",
      path: "예시 공간 / 아이디어 / 단축키 런처 스케치.md", updated: "2026-10-20",
      tags: ["아이디어","단축키","제품"], links: ["i1","p2","p5"],
      body: [
        "작업 중 떠오른 키워드를 빠르게 입력할 수 있도록 단축키로 호출하는 작은 창을 만든다. 닫으면 하던 작업으로 돌아간다.",
        "입력창에 바로 초점을 맞추고 위아래 방향키로 결과를 고른다. Enter로 문서를 읽고 Escape로 닫는다. 한글을 조합하는 동안 키 입력이 가로채지지 않게 한다.",
        "초기 버전에서는 창의 분위기와 검색 흐름을 먼저 확인한다. 실제 파일 연결, 개인화, 검색 범위 설정은 사용감이 정해진 다음 검토한다.",
      ],
    },
    {
      id: "i4", title: "숫자에서 문서로", short: "숫자에서 문서로", topic: "idea", kind: "아이디어 노트",
      path: "예시 공간 / 아이디어 / 숫자에서 문서로.md", updated: "2026-09-24",
      tags: ["아이디어","대시보드","연결"], links: ["f4","p3","i1"],
      body: [
        "대시보드의 숫자를 누르면 그 숫자를 설명하는 문서와 거래를 함께 볼 수 있을까? 값 자체보다 맥락을 찾는 도구가 있으면 좋겠다.",
        "정산액이 바뀐 이유를 확인할 때 정의 문서, 환불 기록, 고객 문의가 이어져 보이도록 생각해 본다.",
        "모든 것을 연결하는 대신 현재 질문에 답하는 관계만 보여준다. 문서를 발견한 이유를 짧은 문장으로 설명하는 것도 중요하다.",
      ],
    },
    {
      id: "i5", title: "흩어진 메모를 다시 읽기", short: "메모를 다시 읽기", topic: "idea", kind: "생각 메모",
      path: "예시 공간 / 아이디어 / 흩어진 메모를 다시 읽기.md", updated: "2026-08-29",
      tags: ["아이디어","기록","가설"], links: ["i2","p4","i1"],
      body: [
        "메모를 저장하는 속도에 비해 다시 읽는 횟수는 적다. 제목을 기억하지 못하면 분명 적어 둔 생각도 찾기 어렵다.",
        "오늘 다루는 주제와 태그를 공유하는 과거의 메모를 몇 개 보여주면 다시 읽을 계기가 생길 수 있다. 관계가 약한 추천은 표시하지 않거나 이유를 함께 보여준다.",
        "연결이 많다는 사실만으로 좋은 기록은 아니다. 지금 필요한 생각으로 돌아오는 길을 짧게 만드는 것이 목표다.",
      ],
    },
  ],
};

// v0.5 예시 사서 (docs/V05.md §9.9): 브리지 없는 화면(Graph.html)과 dev/ui 모의 브리지가 같이 쓴다.
// SynapseDemoBrain.create(docs, { scenario, emit }) → { call(method, params) → Promise<JSON> }
// scenario: 'full'(기본) | 'empty' | 'sessions'(세션 옵트인 카드) | 'stopped' | 'queue' | 'week' | 'nobrain'(모든 호출 실패)
// v0.8: + 'tickets'(티켓 예시 14개) | 'jira'(티켓 + 정리함에 Jira 카드 2장). Claude 연결(aiStatus·aiDigest·aiTask·jiraApply …)은 window.__MOCK_AI 로 상태를 고른다 — 아래 createAI 머리말 참고.
// 숫자는 화면 확인용 가짜 값이다. 시각 표시는 지금 시각을 기준으로 만든다.
(function () {
  'use strict';
  const P2 = n => String(n).padStart(2, '0');
  const DAYS = ['일', '월', '화', '수', '목', '금', '토'];
  const MIN = 60000, HOUR = 3600000, DAY = 86400000;
  const day0 = t => { const d = new Date(t); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };
  const hm = t => { const d = new Date(t); return P2(d.getHours()) + ':' + P2(d.getMinutes()); };
  const ymd = t => { const d = new Date(t); return d.getFullYear() + '-' + P2(d.getMonth() + 1) + '-' + P2(d.getDate()); };
  const md = t => { const d = new Date(t); return (d.getMonth() + 1) + '/' + d.getDate(); };
  function label(t, now) {
    const diff = Math.round((day0(now) - day0(t)) / DAY);
    if (diff === 0) return '오늘 ' + hm(t);
    if (diff === 1) return '어제 ' + hm(t);
    return md(t);
  }
  function dueLabel(due, now) {
    const d = Math.round((day0(due) - day0(now)) / DAY);
    return d < 0 ? '기한 지남' : d === 0 ? '기한 오늘' : d === 1 ? '기한 내일' : '기한 D-' + d;
  }
  const ACTOR = { human: '내가 수정', claude: 'Claude가 작성', codex: 'Codex가 작성', mixed: '함께 작성' };
  const TIER = { now: '지금', week: '이번 주', dormant: '잠듦', none: '' };
  const INSTR = {
    queue: 'Synapse MCP의 list_pending으로 자리가 정해지지 않은 문서를 확인하고, get_vault_policy 규칙에 맞게 propose_changes로 이동 제안을 올려 줘. 파일을 직접 옮기지 말고 제안만 해 줘. 승인은 내가 Synapse 정리함에서 할게.',
    policy: '볼트 루트 CLAUDE.md를 읽고 Synapse get_vault_policy 결과와 다른 점을 찾아서, 규칙표 수정안을 propose_changes(kind: rules)로 올려 줘.',
    violations: 'Synapse get_vault_policy의 violations 목록을 보고 프로젝트_요약.md 등에 빠진 항목을 채워 줘. 바꾸기 전에 바뀔 내용을 먼저 보여 줘.',
    week: 'Synapse MCP의 get_work_context(period: week)로 이번 주 활동을 가져와서 주간보고 형식으로 정리해 줘.',
  };

  // ===========================================================================
  // v0.8 예시 Claude 연결 (docs/V08.md §7·§8.6): aiStatus · setAISetting · aiTest · aiDigest · aiTask · aiCancel · aiRuns · aiRun · jiraPropose · jiraApply · copyRich
  // 계약 모양 그대로 흉내 낸다. 이벤트는 window.synapseAIEvent(src/ai.js)로 보낸다. 실제 Claude·Jira는 부르지 않는다.
  // 시나리오 window.__MOCK_AI (실행 중에 바꿔도 다음 호출부터 따른다):
  //   'on'(기본) 첫 호출은 running → 1.5초 뒤 digest 이벤트 · 'ready' 정리가 이미 있음 · 'off' 꺼짐 · 'missing' Claude 없음 · 'login' 로그인 필요 ·
  //   'running' 계속 실행 중(처음) · 'rerun' 이전 정리 + 계속 실행 중 · 'error' 답을 읽지 못함 · 'errorOld' 이전 정리 + 시간 초과 ·
  //   'limit' 사용 한도 · 'manual' 자동 정리 꺼짐 · 'stale' 입력이 바뀜 · 'empty' 정리할 내용 없음
  // 티켓 자료(tickets)는 사서 시나리오 'tickets'·'jira' 또는 window.__MOCK_TICKETS=true 일 때만 있다(그 밖에는 예전처럼 "예시 자료에는 티켓이 없어요").
  // window.__MOCK_JIRA_FAIL = true 이면 다음 jiraApply 한 번이 실패한다(다시 시도 흐름 확인용).
  const DEFAULT_REPORT_TEMPLATE = [
    "[보고 대상] 팀 주간 회의 문서의 우리 팀 부분에 붙여 넣을 글이에요.",
    "[형식]",
    "- 첫 줄은 팀 이름이에요. 입력에서 알 수 없으면 \"우리 팀\"이라고 써요.",
    "- 기능·주제 단위로 묶은 글머리표를 쓰고, 묶음 끝에 상태(완료·진행 중·보류·예정)를 붙여요. 예: \"- 설정 화면 개선 작업 진행 중\"",
    "- 묶음 아래에는 2칸 들여쓴 글머리표로, 무엇이 가능해졌는지·무엇을 고쳤는지 한 줄 문장으로 써요. 사용자나 담당자가 무엇을 할 수 있게 됐는지로 풀어 써요.",
    "- 작은 수정은 \"- 추가 개선사항\" 아래에 2칸 들여쓴 짧은 항목으로 모아요.",
    "- 마지막 줄은 \"- 다음 주에는 …할 예정입니다.\"",
    "[문체] \"~했습니다\", \"~할 수 있습니다\", \"~진행 중입니다\". 티켓 번호·파일명·코드 이름·내부 약어는 쓰지 않아요. 이모지·굵게·표 없이 글머리표만 써요.",
    "[범위] 이번 주에 끝냈거나 상태가 바뀐 일 중심이에요. 같은 일은 한 줄로 합치고, 근거가 없는 일은 쓰지 않아요.",
  ].join('\n');
  const AI_PRESETS = [
    { id: 'week', title: '이번 주 다시 정리', hint: '이번 주 한 일·다음 주 계획을 Claude가 다시 읽고 정리해요', needs: null },
    { id: 'tickets', title: '티켓 다시 정리', hint: '열린 티켓을 주제별로 묶고 지금 볼 것을 골라 줘요', needs: null },
    { id: 'tidy', title: '정리 계획 다시 만들기', hint: '폴더와 파일을 Claude가 훑어 옮길 곳을 제안해요', needs: null },
    { id: 'organize', title: '정리 안 된 문서 자리 찾기', hint: '정리 규칙에 맞는 자리를 찾아 이동 제안을 올려요', needs: null },
    { id: 'ticket-cleanup', title: '멈춘 티켓 정리 제안', hint: '오래 멈춘 내 티켓에 상태 확인 댓글·전환을 제안해요', needs: null },
    { id: 'doc-summary', title: '이 문서 요약', hint: '열려 있는 문서를 세 문장으로 요약해요', needs: 'doc' },
  ];
  const AI_ERR = {
    login: 'Claude Code 로그인이 필요해요. 터미널에서 claude를 실행해 /login 해 주세요.',
    limit: 'Claude 사용 한도에 닿았어요. 오후 3시쯤 다시 쓸 수 있어요.',
    bad_output: 'Claude 답을 읽지 못했어요. 다시 정리해 보세요.',
    timeout: '시간이 너무 오래 걸려 멈췄어요.',
    network: '인터넷 연결을 확인해 주세요.',
    missing: 'Claude Code를 찾지 못했어요. 설치했다면 설정에서 경로를 골라 주세요.',
  };
  const STEP_TEXT = {
    search_notes: q => '노트 검색: ' + q, get_note: () => '문서 읽기', related_notes: () => '연결 문서 보기', recent_notes: () => '최근 문서 보기',
    get_work_context: () => '작업 맥락 보기', get_vault_policy: () => '정리 규칙 확인', list_pending: () => '정리 안 된 문서 보기',
    suggest_location: t => '둘 곳 추천: ' + t, get_tickets: () => '티켓 보기',
    propose_changes: n => '정리 제안 올리기(' + n + '개)', propose_jira_changes: n => 'Jira 제안 올리기(' + n + '개)',
  };
  const aiWait = ms => new Promise(r => setTimeout(r, ms));
  const aiRid = () => 'r_' + Array.from({ length: 12 }, () => '0123456789abcdef'[Math.floor(Math.random() * 16)]).join('');
  const aiRef = (ref, docId, line, key, title, kind) => ({ ref, docId, line: line == null ? null : line, key: key || null, title, kind });
  const htmlEsc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  // 보고 글(들여쓴 "- " 목록) → 중첩 <ul><li> (Confluence에 붙이면 글머리표가 산다). 목록이 아닌 줄은 <p>.
  function reportToHTML(text) {
    let html = '', lvl = -1;
    const close = to => { while (lvl > to) { html += '</li></ul>'; lvl--; } };
    String(text || '').split('\n').forEach(line => {
      const m = /^(\s*)-\s+(.*)$/.exec(line);
      if (!m) { close(-1); if (line.trim()) html += '<p>' + htmlEsc(line.trim()) + '</p>'; return; }
      const d = Math.floor(m[1].length / 2);
      if (d > lvl) { while (lvl < d) { html += '<ul>'; lvl++; if (lvl < d) html += '<li>'; } html += '<li>' + htmlEsc(m[2]); }
      else { close(d); html += '</li><li>' + htmlEsc(m[2]); }
    });
    close(-1);
    return html;
  }

  // 예시 티켓 (카페 주문 앱 팀): [키, 제목, 상태, 묶음, 우선순위, 유형, 내 티켓, 담당, 갱신 며칠 전, 진행 며칠째, 기한까지 며칠, 문서 id]
  const DEMO_TICKETS = [
    ['CAFE-101', '메뉴 추천: 추천 목록 조회 API', '진행 중', 'doing', 'High', '작업', true, null, 1, 6, null, 'f1'],
    ['CAFE-102', '로그 보관 기간 조정', '진행 중', 'doing', 'Medium', '작업', true, null, 34, 42, null, 'f2'],
    ['CAFE-103', '쿠폰 만료 처리 배치 개선', '진행 중', 'doing', 'Medium', '작업', true, null, 9, 15, null, 'f3'],
    ['POS-201', '매장 영업시간 동기화 개선', '진행 중', 'doing', 'High', '작업', false, '김철수', 2, 5, null, 's1'],
    ['CAFE-104', '리워드 등급 기준 일정 확정', '보류', 'blocked', 'High', '작업', false, '박민수', 12, 20, null, 'f4'],
    ['CAFE-105', '메뉴 추천: 추천 노출 정보 구조 정리', '해야 할 일', 'todo', 'Medium', '작업', true, null, 2, null, 5, 'f5'],
    ['CAFE-106', '주문 대기열 화면: 상태 필터 추가', '해야 할 일', 'todo', 'Medium', '작업', true, null, 3, null, 3, 's2'],
    ['CAFE-107', '픽업 알림 발송 지연 확인 화면', '해야 할 일', 'todo', 'Medium', '작업', false, null, 4, null, null, 's3'],
    ['CAFE-108', '픽업 준비 알림 문구 변경', '해야 할 일', 'todo', 'Low', '작업', true, null, 1, null, null, 's4'],
    ['CAFE-109', '쿠폰 발급 내역 조회 API', '해야 할 일', 'todo', 'Medium', '작업', false, '이영희', 6, null, null, 's5'],
    ['POS-202', '스탬프 적립 중복 기록 수정', '해야 할 일', 'todo', 'High', '버그', true, null, 0, null, 1, 'p1'],
    ['POS-203', '매장별 주문 내역 CSV 다운로드', '해야 할 일', 'todo', 'Low', '작업', false, null, 8, null, null, 'p2'],
    ['POS-204', '품절 표시 동기화 확인', '해야 할 일', 'todo', 'Medium', '작업', false, '김철수', 5, null, null, 'p3'],
    ['POS-205', '이벤트 배너 노출 기록 정리', '해야 할 일', 'todo', 'Low', '작업', false, null, 10, null, null, 'p4'],
  ];
  const PRIO_RANK = { High: 1, Medium: 2, Low: 3 };
  const agoWord = n => (n <= 0 ? '오늘' : n === 1 ? '어제' : n + '일 전');

  function createAI(ctx) {
    const T0 = ctx.T0, t = ctx.t;
    const scen = () => String(window.__MOCK_AI || ctx.ai || 'on');
    const S = { enabled: true, auto: true, found: true, login: 'unknown', path: '', template: '', usedToday: 3, models: { digest: 'sonnet', task: 'opus' } };
    const store = new Map();        // 'kind|scope' → {digest, meta, stale}
    const fails = new Map();        // 'kind|scope' → {code, message, at}
    const lastStart = new Map();    // 'kind|scope' → 마지막 실행을 시작한 시각(ms). 자동 정리는 20분 쉰다 (§4.3)
    const active = [];              // 지금 도는 실행 {id, kind, digestKind, scope, title, started, timer, key}
    const history = [];             // 실행 기록 (최근 순)
    const proposed = new Map();     // 카드 id → 카드 (모든 상태: pending|applied|rejected|failed)
    let lastScen = null, runNo = 0, cardNo = 0;
    const emitAI = e => setTimeout(() => { if (typeof window.synapseAIEvent === 'function') window.synapseAIEvent(e); }, 15);
    const mondayOf = off => day0(T0) - ((new Date(T0).getDay() + 6) % 7) * DAY + off * 7 * DAY;
    const weekScope = off => ymd(mondayOf(off));
    const labelOf = at => label(at, Math.max(at, T0));

    // ---------- 예시 티켓 ----------
    function ticketRows() {
      const now = Date.now();
      return DEMO_TICKETS.map(([key, title, status, group, priority, issueType, mine, who, upd, since, due, docId]) => {
        const updated = now - upd * DAY, dueAt = due == null ? null : day0(now) + due * DAY;
        const stale = group === 'doing' && upd > 7;
        const it = { docId, key, title, status, statusGroup: group, priority, priorityRank: PRIO_RANK[priority] == null ? 5 : PRIO_RANK[priority], mine, issueType,
          updated: new Date(updated).toISOString(), updatedLabel: agoWord(upd), stale };
        if (who) it.assigneeName = who;
        if (since != null) { it.since = new Date(now - since * DAY).toISOString(); it.sinceLabel = (group === 'doing' ? '진행 중' : status) + ' ' + since + '일째'; }
        if (dueAt != null) { it.due = ymd(dueAt); it.dueLabel = dueLabel(dueAt, now); }
        return it;
      });
    }
    const counts = rows => { const c = { blocked: 0, doing: 0, todo: 0, stale: 0 }; rows.forEach(r => { c[r.statusGroup]++; if (r.stale) c.stale++; }); return c; };
    function ticketsCall(p) {
      const all = ticketRows(), rows = p && p.mine ? all.filter(r => r.mine) : all;
      const order = (a, b) => {
        const ga = { blocked: 0, doing: 1, todo: 2 }[a.statusGroup], gb = { blocked: 0, doing: 1, todo: 2 }[b.statusGroup];
        if (ga !== gb) return ga - gb;
        if (a.statusGroup !== 'todo') { if (a.stale !== b.stale) return a.stale ? -1 : 1; return a.updated < b.updated ? -1 : 1; }
        if (!!a.due !== !!b.due) return a.due ? -1 : 1;
        if (a.due && b.due && a.due !== b.due) return a.due < b.due ? -1 : 1;
        return a.priorityRank - b.priorityRank || (a.key < b.key ? -1 : 1);
      };
      const by = {};
      rows.forEach(r => { (by[r.key.split('-')[0]] = by[r.key.split('-')[0]] || []).push(r); });
      const projects = Object.keys(by).map(k => ({ key: k, label: k, counts: counts(by[k]), items: by[k].sort(order) }))
        .sort((a, b) => b.counts.blocked - a.counts.blocked || b.counts.doing - a.counts.doing || b.items.length - a.items.length || (a.key < b.key ? -1 : 1));
      const totals = counts(all); totals.mine = all.filter(r => r.mine).length;
      return { generatedAt: new Date(Date.now()).toISOString(), hasJira: true, projects, totals, blockedRule: { closedLike: ["Won't Do", 'Duplicate'] } };
    }
    const tk = key => DEMO_TICKETS.find(x => x[0] === key);
    const tkRef = (n, key) => { const x = tk(key); return aiRef('J' + n, x[11], null, key, x[1], 'issue'); };

    // ---------- 예시 정리 내용 ----------
    function weekDigest(off) {
      const R = {
        refund: aiRef('T1', 'f3', 3, null, '환불 정책 표 정리', 'task'), notice: aiRef('T2', 'f3', 5, null, '환불 안내 문구 확정', 'task'),
        pay141: aiRef('J1', 'f2', null, 'PAY-141', '결제 상태 전이 검토', 'issue'), pay147: aiRef('J2', 'f5', null, 'PAY-147', '중복 요청 방지 체크', 'issue'),
        dash: aiRef('T3', 'f4', 3, null, '정산 대시보드 숫자 정의 확인', 'task'), cards: aiRef('T4', 'f4', 2, null, '정산 대시보드 카드 순서 확정', 'task'),
        tn004: aiRef('D1', 's2', null, null, 'TN-004 검색 색인 메모', 'doc'), syn: aiRef('T5', 's2', 4, null, '동의어 사전 갱신', 'task'),
        churn: aiRef('T6', 'p4', 3, null, '이탈 가설 인터뷰 질문 만들기', 'task'), flow: aiRef('H1', 'p4', null, null, '고객 이탈 가설', 'thread'),
        retry: aiRef('D2', 'f2', null, null, '결제 실패 재시도 정책 초안', 'doc'), intv: aiRef('T7', 'p1', 2, null, '고객 인터뷰 정리', 'task'),
        share: aiRef('D3', 'p3', null, null, '매출 지표 정의', 'doc'), rank: aiRef('D4', 's5', null, null, '검색 결과 순위 실험', 'doc'),
      };
      let d;
      if (off === 0) {
        d = {
          headline: '정산·환불 흐름 정리가 이번 주의 중심이었어요. 환불 정책 표와 결제 상태 전이 검토를 끝냈고, 환불 안내 문구는 오늘까지예요.',
          sections: [
            { title: '환불 정책·안내', state: 'doing', items: [
              { text: '부분 환불과 재환불 기준을 한 표로 정리했어요', state: 'done', refs: [R.refund] },
              { text: '환불 안내 문구에 접수와 환불 완료의 차이를 담는 일이 남았어요', state: 'todo', refs: [R.notice] } ] },
            { title: '결제 상태 전이', state: 'mixed', items: [
              { text: '승인 대기·승인 완료·취소 단계의 전환 규칙 검토를 끝냈어요', state: 'done', refs: [R.pay141] },
              { text: '같은 승인 요청이 여러 번 와도 한 번만 처리하는지 점검하고 있어요', state: 'doing', refs: [R.pay147] } ] },
            { title: '정산 대시보드', state: 'doing', items: [
              { text: '매출·결제·정산·입금 숫자의 정의를 확인했어요', state: 'done', refs: [R.dash] },
              { text: '요약 카드 순서를 정하는 일이 이어져요', state: 'todo', refs: [R.cards] } ] },
            { title: '검색·색인', state: 'mixed', items: [
              { text: '검색 색인 메모(TN-004)를 작성했어요', state: 'done', refs: [R.tn004] },
              { text: '동의어 사전 갱신은 기한이 5일 남았어요', state: 'todo', refs: [R.syn] } ] },
            { title: '고객 이탈 가설', state: 'planned', items: [
              { text: '인터뷰 질문을 만들어 가설을 확인할 예정이에요', state: 'todo', refs: [R.churn] } ] },
          ],
          next: [
            { text: '환불 안내 문구 확정', why: '기한이 오늘이라 가장 먼저 닫아야 해요', refs: [R.notice] },
            { text: '중복 요청 방지 체크 마무리', why: '내일이 기한이고 결제 안정성과 이어져 있어요', refs: [R.pay147] },
            { text: '동의어 사전 갱신', why: '기한이 5일 남아서 이번 주에 시작하면 여유 있어요', refs: [R.syn] },
            { text: '정산 대시보드 카드 순서 확정', why: '숫자 정의가 끝나서 바로 이어서 할 수 있어요', refs: [R.cards] },
          ],
          risks: [
            { text: '환불 안내 문구가 오늘 기한인데 아직 열려 있어요', refs: [R.notice] },
            { text: '고객 이탈 가설은 3일째 손대지 않아 인터뷰 일정이 밀릴 수 있어요', refs: [R.flow] },
          ],
          skipped: { count: 12, note: '지침 문서의 체크박스와 보관함 문서의 완료 표시는 뺐어요' },
          report: [
            '우리 팀',
            '- 환불 정책·안내 정리 진행 중',
            '  - 부분 환불과 재환불 기준을 한 표로 정리해, 상담에서 같은 기준으로 안내할 수 있습니다.',
            '  - 환불 접수와 실제 환불 완료의 차이를 안내 문구에 담는 작업을 진행 중입니다.',
            '- 결제 상태 전이 검토 완료',
            '  - 승인 대기·승인 완료·취소 단계의 전환 규칙을 점검해, 같은 요청이 한 번만 처리되는 흐름을 확인했습니다.',
            '- 정산 대시보드 진행 중',
            '  - 매출·결제·정산·입금 숫자의 정의를 확인해, 운영팀이 같은 기준으로 숫자를 볼 수 있습니다.',
            '- 추가 개선사항',
            '  - 검색 색인 메모를 작성해 문서 검색 품질을 개선할 기준을 마련했습니다.',
            '- 다음 주에는 환불 안내 문구 확정과 정산 대시보드 카드 구성을 진행할 예정입니다.',
          ].join('\n'),
        };
      } else {
        d = {
          headline: '지난주는 결제 실패 재시도 정책 초안과 고객 인터뷰 정리를 끝냈어요.',
          sections: [
            { title: '결제 실패 재시도', state: 'done', items: [
              { text: '결제가 실패했을 때 몇 번까지 다시 시도할지 정책 초안을 썼어요', state: 'done', refs: [R.retry] } ] },
            { title: '고객 인터뷰', state: 'done', items: [
              { text: '고객 인터뷰 내용을 모아 불편한 점을 정리했어요', state: 'done', refs: [R.intv] } ] },
            { title: '정산 대시보드', state: 'planned', items: [
              { text: '지표 정의를 먼저 맞추고 초안 공유는 이번 주로 넘겼어요', state: 'todo', refs: [R.share] } ] },
          ],
          next: [
            { text: '정산 대시보드 초안 공유', why: '지난주 계획에 있던 일이에요', refs: [R.share] },
            { text: '검색 순위 실험 결과 정리', why: '실험은 끝났고 정리만 남았어요', refs: [R.rank] },
          ],
          risks: [],
          skipped: { count: 3, note: '이미 닫힌 보관 문서의 완료 표시는 뺐어요' },
          report: [
            '우리 팀',
            '- 결제 실패 재시도 정책 완료',
            '  - 결제가 실패했을 때 다시 시도하는 횟수와 간격의 기준을 정리했습니다.',
            '- 고객 인터뷰 정리 진행 중',
            '  - 고객이 환불 진행 상태를 알기 어려워한다는 의견을 모아 개선 방향을 정리했습니다.',
            '- 다음 주에는 정산 대시보드 초안 공유와 검색 순위 실험 결과 정리를 진행할 예정입니다.',
          ].join('\n'),
        };
      }
      d.reportHTML = reportToHTML(d.report);
      return d;
    }
    function ticketsDigest() {
      const k = (n, key) => tkRef(n, key);
      const lines = {
        'CAFE-101': '추천 메뉴를 목록으로 불러오는 API를 만드는 중이에요', 'CAFE-105': '추천에 어떤 정보를 보여 줄지 데이터 구조를 정리해요',
        'CAFE-109': '발급된 쿠폰 내역을 조회하는 API예요', 'CAFE-102': '서버에 쌓이는 로그를 얼마나 오래 보관할지 정해요',
        'CAFE-107': '픽업 알림이 늦게 나가면 알려 주는 확인 화면이에요', 'CAFE-106': '주문 대기열 화면에서 상태별로 주문을 걸러 볼 수 있게 해요',
        'CAFE-108': '픽업 준비 알림에 들어가는 문구를 바꿔요', 'CAFE-103': '만료된 쿠폰을 정리하는 배치를 빠르게 만들어요',
        'CAFE-104': '리워드 등급 기준을 바꿀 날짜를 정해요', 'POS-201': '매장 영업시간이 앱에 제때 반영되도록 동기화를 개선해요',
        'POS-202': '같은 스탬프가 여러 번 적립되는 문제를 고쳐요', 'POS-203': '매장별 주문 내역을 CSV 파일로 받을 수 있게 해요',
        'POS-204': '품절 표시가 매장과 앱에서 같은지 지켜봐요', 'POS-205': '이벤트 배너가 몇 번 보였는지 기록을 정리해요',
      };
      return {
        headline: '막힌 티켓은 보류 1개뿐이에요. 34일째 멈춘 CAFE-102와 메뉴 추천 두 건을 먼저 보세요.',
        focus: [
          { ref: k(1, 'CAFE-102'), why: '진행 중인데 34일째 갱신이 없어요', action: '담당 상태를 확인하고 댓글 남기기' },
          { ref: k(2, 'CAFE-101'), why: '메뉴 추천의 첫 단계예요', action: '추천 목록 API 검토 요청하기' },
          { ref: k(3, 'POS-202'), why: '기한이 내일이고 우선순위가 높아요', action: '중복 적립 원인 확인하기' },
          { ref: k(4, 'CAFE-104'), why: '보류 12일째라 일정이 밀려요', action: '재개 조건을 정해 일정 잡기' },
        ],
        themes: [
          { title: '메뉴 추천·쿠폰', summary: '추천 목록·노출 정보와 쿠폰 발급 내역 API를 차례로 만드는 중이에요', refs: [k(2, 'CAFE-101'), k(5, 'CAFE-105'), k(6, 'CAFE-109')] },
          { title: '운영 개선', summary: '로그 보관 기간과 픽업 알림 확인 화면을 손봐요', refs: [k(1, 'CAFE-102'), k(7, 'CAFE-107')] },
          { title: '주문 화면·알림 개선', summary: '주문 대기열 필터와 픽업 알림 문구를 바꿔요', refs: [k(8, 'CAFE-106'), k(9, 'CAFE-108')] },
          { title: '배치·일정 정리', summary: '쿠폰 만료 배치 개선과 리워드 등급 일정이에요', refs: [k(10, 'CAFE-103'), k(4, 'CAFE-104')] },
          { title: '매장 POS 연동', summary: '영업시간·스탬프 적립·주문 내역 CSV·품절 표시예요', refs: [k(11, 'POS-201'), k(3, 'POS-202'), k(12, 'POS-203'), k(13, 'POS-204')] },
        ],
        lines,
        cleanup: [
          { ref: k(1, 'CAFE-102'), op: 'comment', body: '이 티켓이 34일째 진행 중으로 남아 있어요. 로그 보관 기간 조정이 어디까지 진행됐는지 공유해 주실 수 있을까요? 막힌 부분이 있으면 함께 볼게요.', why: '34일째 갱신이 없어요' },
          { ref: k(10, 'CAFE-103'), op: 'transition', to: '해야 할 일', why: '9일째 진행 중 표시만 남아 있어요' },
          { ref: k(4, 'CAFE-104'), op: 'comment', body: '보류 사유와 다시 시작할 조건을 정리해서 남겨 주세요. 일정을 잡을 때 참고할게요.', why: '보류가 12일째예요' },
        ],
      };
    }
    function homeDigest() {
      return {
        headline: '오늘은 환불 안내 문구 확정이 먼저예요.',
        today: [
          { text: '환불 안내 문구를 확정해요', why: '기한이 오늘이에요', refs: [aiRef('T1', 'f3', 5, null, '환불 안내 문구 확정', 'task')] },
          { text: '중복 요청 방지 체크를 마무리해요', why: '내일이 기한이에요', refs: [aiRef('J1', 'f5', null, 'PAY-147', '중복 요청 방지 체크', 'issue')] },
          { text: '정산 대시보드 카드 순서를 정해요', why: '숫자 정의를 끝내서 바로 이어 갈 수 있어요', refs: [aiRef('T2', 'f4', 2, null, '정산 대시보드 카드 순서 확정', 'task')] },
        ],
      };
    }
    function docDigest(docId) {
      const d = ((window.SYNAPSE_DATA && window.SYNAPSE_DATA.docs) || []).find(x => x.id === docId);
      const body = d && d.body ? d.body : [];
      const first = s => { const m = String(s || '').match(/^.*?[.?!。](\s|$)/); return (m ? m[0] : String(s || '')).trim(); };
      return {
        summary: body.slice(0, 2).map(first).join(' ') || '이 문서는 아직 요약할 내용이 없어요.',
        points: body.map(first).filter(Boolean).slice(0, 3),
        todos: docId === 'f3' ? ['환불 안내 문구에 접수와 환불 완료의 차이 쓰기'] : docId === 'f4' ? ['요약 카드 순서 정하기'] : [],
      };
    }
    function buildDigest(kind, scope) {
      if (kind === 'week') return weekDigest(scope === weekScope(0) ? 0 : -1);
      if (kind === 'tickets') return ticketsDigest();
      if (kind === 'home') return homeDigest();
      if (kind === 'tidy') return { summary: ctx.tidy ? ctx.tidy.summary() : '', items: [], questions: [] };
      return docDigest(scope);
    }
    function put(kind, scope, at, stale, runId, durationMs) {
      store.set(kind + '|' + scope, { digest: buildDigest(kind, scope),
        meta: { created: at / 1000, createdLabel: labelOf(at), model: S.models.digest, durationMs: durationMs || 12000, runId: runId || aiRid() }, stale: !!stale });
    }

    // ---------- 시나리오 ----------
    function syncScenario() {
      const sc = scen();
      if (sc === lastScen) return;
      lastScen = sc;
      active.splice(0).forEach(r => clearTimeout(r.timer));
      store.clear(); fails.clear(); lastStart.clear();
      S.enabled = sc !== 'off'; S.found = sc !== 'missing'; S.auto = sc !== 'manual'; S.login = 'unknown'; S.usedToday = 3;
      if (sc === 'ready' || sc === 'stale' || sc === 'rerun' || sc === 'errorOld') {
        const at = T0 - 25 * MIN;
        [['week', weekScope(0)], ['week', weekScope(-1)], ['tickets', 'all'], ['home', 'today']].forEach(([k, s]) => { put(k, s, at, sc === 'stale'); if (sc === 'stale') lastStart.set(k + '|' + s, T0 - 5 * MIN); });
        if (sc === 'errorOld') [['week', weekScope(0)], ['tickets', 'all'], ['home', 'today']].forEach(([k, s]) => fails.set(k + '|' + s, { code: 'timeout', message: AI_ERR.timeout, at: T0 / 1000 - 300 }));
      }
      if (sc === 'limit') fails.set('week|' + weekScope(0), { code: 'limit', message: AI_ERR.limit, at: T0 / 1000 - 120 });
      if (sc === 'limit') fails.set('tickets|all', { code: 'limit', message: AI_ERR.limit, at: T0 / 1000 - 120 });
    }
    const scopeOf = (kind, p) => kind === 'week' ? weekScope(Math.min(0, Math.round(Number(p.offset) || 0))) : kind === 'tickets' ? 'all' : kind === 'home' ? 'today' : kind === 'tidy' ? 'daily-' + ymd(T0) : String(p.docId || '');
    const TITLE = { week: '이번 주 정리', tickets: '티켓 정리', home: '오늘 정리', doc: '문서 요약', tidy: '정리 계획' };

    function record(r) { history.unshift(r); if (history.length > 40) history.pop(); }
    function startDigest(kind, scope) {
      const id = aiRid(), key = kind + '|' + scope;
      lastStart.set(key, Date.now());
      const run = { id, kind: 'digest', digestKind: kind, scope, key, title: kind === 'week' && scope !== weekScope(0) ? '지난주 정리' : TITLE[kind], started: Date.now(), timer: 0 };
      active.push(run);
      record({ runId: id, kind: 'digest', digestKind: kind, scope, title: run.title, prompt: run.title, status: 'running', started: run.started / 1000, ended: null, model: S.models.digest, turns: 0, durationMs: 0, steps: [], answer: '', error: null, proposals: [] });
      emitAI({ type: 'status' });
      emitAI({ type: 'run', runId: id, kind: 'digest', status: 'running' });
      const sc = scen();
      if (sc === 'running' || sc === 'rerun') return run;      // 끝나지 않는다 (화면 확인용)
      run.timer = setTimeout(() => finishDigest(run), 1500);
      return run;
    }
    function finishDigest(run) {
      const i = active.indexOf(run); if (i < 0) return;
      active.splice(i, 1);
      const rec = history.find(h => h.runId === run.id), sc = scen(), now = Date.now();
      const failCode = sc === 'login' ? 'login' : sc === 'error' ? 'bad_output' : sc === 'errorOld' ? 'timeout' : sc === 'limit' ? 'limit' : !S.enabled ? 'failed' : null;
      if (failCode) {
        if (failCode === 'login') S.login = 'needed';
        fails.set(run.key, { code: failCode, message: AI_ERR[failCode] || 'Claude 실행이 실패했어요', at: now / 1000 });
        if (rec) Object.assign(rec, { status: 'error', ended: now / 1000, durationMs: now - run.started, error: { code: failCode, message: AI_ERR[failCode] } });
        emitAI({ type: 'run', runId: run.id, kind: 'digest', status: 'error' });
      } else {
        const dur = 9000 + (++runNo * 1700) % 7000;
        put(run.digestKind, run.scope, now, false, run.id, dur);
        if (run.digestKind === 'tidy' && ctx.tidy) ctx.tidy.planDone();
        fails.delete(run.key); S.login = 'ok'; S.usedToday++;
        if (rec) Object.assign(rec, { status: 'done', ended: now / 1000, durationMs: dur, turns: 2 });
        emitAI({ type: 'run', runId: run.id, kind: 'digest', status: 'done' });
      }
      emitAI({ type: 'digest', kind: run.digestKind, scope: run.scope });
      emitAI({ type: 'status' });
    }

    // ---------- 브리지 ----------
    function aiStatus() {
      syncScenario();
      return { ok: true, available: S.enabled && S.found, enabled: S.enabled, auto: S.auto,
        claude: { found: S.found, path: S.found ? (S.path || '~/.local/bin/claude') : null, version: S.found ? '2.1.310' : null, login: S.found ? S.login : 'unknown', error: S.found ? null : AI_ERR.missing },
        models: { digest: S.models.digest, task: S.models.task },
        running: active.map(r => ({ runId: r.id, kind: r.kind, digestKind: r.digestKind || null, scope: r.scope || null, title: r.title, started: r.started / 1000 })),
        report: { template: S.template || DEFAULT_REPORT_TEMPLATE, isDefault: !S.template },
        presets: AI_PRESETS.map(x => Object.assign({}, x)),
        limits: { autoPerDay: 24, autoUsedToday: S.usedToday } };
    }
    function setAISetting(p) {
      syncScenario();
      const key = String(p.key || ''), v = String(p.value == null ? '' : p.value);
      if (['enabled', 'auto', 'model.digest', 'model.task', 'claude.path', 'report.template'].indexOf(key) < 0) return { ok: false, error: '알 수 없는 설정이에요' };
      if (key === 'enabled') S.enabled = v === '1';
      else if (key === 'auto') S.auto = v === '1';
      else if (key === 'model.digest' || key === 'model.task') {
        if (['sonnet', 'opus', 'haiku'].indexOf(v) < 0) return { ok: false, error: '모델은 sonnet, opus, haiku 중에서 골라 주세요' };
        S.models[key === 'model.digest' ? 'digest' : 'task'] = v;
      } else if (key === 'claude.path') { S.path = v; if (v && scen() === 'missing') S.found = true; }
      else S.template = v;
      Array.from(fails.keys()).forEach(k => { const f = fails.get(k); if (f.code === 'login' || f.code === 'missing') fails.delete(k); });   // 설정이 바뀌면 login·missing 기억을 지운다
      emitAI({ type: 'status' });
      return { ok: true, status: aiStatus() };
    }
    function aiTest() {
      return aiWait(900).then(() => {
        syncScenario();
        if (!S.found) return { ok: false, version: null, login: 'unknown', model: S.models.digest, ms: 0, error: AI_ERR.missing };
        if (scen() === 'login') { S.login = 'needed'; emitAI({ type: 'status' }); return { ok: false, version: '2.1.310', login: 'needed', model: 'haiku', ms: 1200, error: AI_ERR.login }; }
        S.login = 'ok';
        Array.from(fails.keys()).forEach(k => { const f = fails.get(k); if (f.code === 'login' || f.code === 'missing') fails.delete(k); });
        emitAI({ type: 'status' });
        return { ok: true, version: '2.1.310', login: 'ok', model: 'haiku', ms: 2800 };
      });
    }
    function aiDigest(p) {
      syncScenario();
      const kind = String(p.kind || '');
      if (['week', 'tickets', 'home', 'doc', 'tidy'].indexOf(kind) < 0) return { ok: false, error: '알 수 없는 정리 종류예요' };
      if (kind === 'doc' && !p.docId) return { ok: false, error: '문서를 골라 주세요' };
      const scope = scopeOf(kind, p), key = kind + '|' + scope, run = p.run === 'force' || p.run === 'auto' ? p.run : 'none', sc = scen();
      const entry = store.get(key) || null, fail = fails.get(key) || null;
      let act = active.find(r => r.key === key) || null, blocked = null;
      if (!S.enabled) blocked = 'disabled';
      else if (!S.found) blocked = 'unavailable';
      else if (run === 'auto') {
        if (kind === 'doc' || !S.auto) blocked = 'manual';
        else if (fail && (fail.code === 'login' || fail.code === 'missing')) blocked = fail.code;
        else if (fail && fail.code === 'limit') blocked = 'limit';
        else if (lastStart.has(key) && Date.now() - lastStart.get(key) < 20 * MIN && sc !== 'rerun') blocked = 'cooldown';
        else if (S.usedToday >= 24) blocked = 'cap';
      }
      const canRun = S.enabled && S.found && !(sc === 'empty');
      if (canRun && !act) {
        if (run === 'force') act = startDigest(kind, scope);
        else if (run === 'auto' && !blocked && (!entry || entry.stale || sc === 'rerun')) act = startDigest(kind, scope);
      }
      const state = sc === 'empty' && !entry ? 'empty' : !entry ? 'missing' : entry.stale ? 'stale' : 'fresh';
      return { ok: true, kind, scope, digest: entry ? entry.digest : null, meta: entry ? entry.meta : null, state,
        running: !!act, runId: act ? act.id : null, blocked: (act && blocked !== 'disabled' && blocked !== 'unavailable') || (blocked === 'manual' && entry && !entry.stale) ? null : blocked,
        error: act ? null : (fail ? { code: fail.code, message: fail.message, at: fail.at } : null) };
    }

    // ----- 시키기 -----
    function moveCard(docId, from, to, runId) {
      const id = 's:ai' + String(++cardNo).padStart(4, '0');
      return ctx.mv(id, docId, from, to, '추천', 'claude', ['정리 규칙의 위치와 맞아요', '같은 폴더 문서와 주제가 비슷해요'], { links: 1, files: 1 }, { run: runId, state: 'pending' });
    }
    function jiraCard(spec, runId) {
      const x = tk(spec.key), id = 's:jr' + String(++cardNo).padStart(4, '0'), now = Date.now();
      return { id, kind: 'jira', op: spec.op, key: spec.key, docId: x ? x[11] : null, title: x ? x[1] : spec.key, status: x ? x[2] : null, to: spec.to || null, body: spec.body || null,
        project: spec.project || spec.key.split('-')[0], issueType: spec.issueType || null, summary: spec.summary || null, description: spec.description || null,
        reason: spec.reason || '', origin: 'claude', originLabel: 'Claude 제안', run: runId || null, state: 'pending', error: null, created: new Date(now).toISOString(), createdLabel: label(now, now),
        confidence: '추천', reasons: spec.reason ? [spec.reason] : [], impact: { links: 0, files: 0, canvas: 0, conflict: null, sync: false }, alternatives: [], items: [], rules: [], violations: [], from: null };
    }
    function taskScript(p, runId) {
      const preset = p.preset || null, prompt = String(p.prompt || '').trim(), ctxDoc = p.context && p.context.docId ? String(p.context.docId) : null;
      const link = id => '[' + t(id) + '](synapse:doc/' + id + ')';
      if (preset === 'organize') {
        const a = moveCard('s3', '_workspace/파일 변경 감지 메모.md', '3-Resources/검색/', runId), b = moveCard('p2', '_Inbox/제품 탐색 경험 개선.md', '2-Areas/제품/기획/', runId);
        return { title: '정리 안 된 문서 자리 찾기', steps: [['get_vault_policy'], ['list_pending'], ['suggest_location', t('s3') + ' 외 1개'], ['propose_changes', 2]], cards: [a, b],
          answer: '정리 안 된 문서 12개 중 규칙에 맞는 **2개**의 자리를 찾아 정리함에 올렸어요.\n\n- ' + link('s3') + ' → `3-Resources/검색/`\n- ' + link('p2') + ' → `2-Areas/제품/기획/`\n\n나머지 10개는 규칙에 맞는 자리가 없거나 확신이 낮아서 올리지 않았어요. 승인은 정리함에서 해 주세요.' };
      }
      if (preset === 'ticket-cleanup') {
        const a = jiraCard({ op: 'comment', key: 'CAFE-102', body: '이 티켓이 34일째 진행 중으로 남아 있어요. 로그 보관 기간 조정이 어디까지 진행됐는지 공유해 주실 수 있을까요?', reason: '34일째 갱신이 없어요' }, runId);
        const b = jiraCard({ op: 'transition', key: 'CAFE-103', to: '해야 할 일', reason: '9일째 진행 중 표시만 남아 있어요' }, runId);
        return { title: '멈춘 티켓 정리 제안', steps: [['get_tickets'], ['get_work_context'], ['propose_jira_changes', 2]], cards: [a, b],
          answer: '멈춘 내 티켓 **2개**에 대한 제안을 올렸어요.\n\n- CAFE-102: 34일째 갱신이 없어서 상태 확인 댓글을 제안했어요.\n- CAFE-103: 9일째 진행 중으로만 남아 있어서 \'해야 할 일\'로 되돌리는 걸 제안했어요.\n\nJira에는 아직 아무것도 바뀌지 않았어요. 반영하려면 정리함에서 승인해 주세요.' };
      }
      if (preset === 'doc-summary') {
        const id = ctxDoc || 'f1', d = docDigest(id);
        return { title: '이 문서 요약', steps: [['get_note'], ['related_notes'], ['get_work_context']], cards: [],
          answer: '**' + t(id) + '** 요약이에요.\n\n' + d.summary + '\n\n' + d.points.map(x => '- ' + x).join('\n') + '\n\n근거: ' + link(id) };
      }
      const q = (prompt || '정산').replace(/\s+/g, ' ').slice(0, 14);
      return { title: prompt ? prompt.slice(0, 40) : '자유 지시', steps: [['get_work_context'], ['search_notes', q], ['get_note'], ['related_notes']], cards: [],
        answer: '\'' + q + '\'와 관련된 문서를 찾아 읽어 봤어요.\n\n- ' + link('f1') + ' — 결제 완료부터 정산 대기 금액 기록까지의 흐름을 정리한 문서예요.\n- ' + link('f3') + ' — 부분 환불 뒤 다시 환불할 때 확인할 점을 모았어요.\n- ' + link('f4') + ' — 정산 예정액·환불 조정액·입금 완료액을 한 화면에 보여 주는 초안이에요.\n\n더 좁혀서 보고 싶으면 날짜나 프로젝트를 알려 주세요.' };
    }
    function aiTask(p) {
      syncScenario();
      if (!S.enabled) return { ok: false, error: 'Claude 정리가 꺼져 있어요. 설정에서 켜 주세요' };
      if (!S.found) return { ok: false, error: AI_ERR.missing };
      if (active.some(r => r.kind === 'task')) return { ok: false, error: '이미 Claude가 일하고 있어요' };
      const preset = p.preset || null;
      if (preset === 'week' || preset === 'tickets' || preset === 'tidy') {
        const scope = preset === 'week' ? weekScope(0) : preset === 'tidy' ? scopeOf('tidy', {}) : 'all', r = startDigest(preset, scope);
        return { ok: true, runId: r.id, digest: { kind: preset, scope } };
      }
      const id = aiRid(), script = taskScript(p, id), started = Date.now();
      const run = { id, kind: 'task', digestKind: null, scope: null, key: 'task', title: script.title, started, timer: 0, timers: [] };
      active.push(run);
      const rec = { runId: id, kind: 'task', digestKind: null, scope: null, title: script.title, prompt: String(p.prompt || script.title), status: 'running', started: started / 1000, ended: null,
        model: S.models.task, turns: 0, durationMs: 0, steps: [], answer: '', error: null, proposals: [] };
      record(rec);
      emitAI({ type: 'status' });
      emitAI({ type: 'run', runId: id, kind: 'task', status: 'running' });
      const at = (ms, fn) => run.timers.push(setTimeout(() => { if (active.indexOf(run) >= 0) fn(); }, ms));
      let when = 600;
      script.steps.forEach(([tool, arg]) => {
        const text = (STEP_TEXT[tool] || (() => tool))(arg);
        at(when, () => { const step = { ts: Date.now() / 1000, kind: 'tool', text, tool, ok: true }; rec.steps.push(step); rec.turns++; emitAI({ type: 'run', runId: id, kind: 'task', status: 'running', step }); });
        when += 900;
      });
      const half = script.answer.slice(0, Math.ceil(script.answer.length / 2));
      at(when, () => { rec.answer = half; emitAI({ type: 'run', runId: id, kind: 'task', status: 'running', text: half }); });
      at(when + 600, () => {
        active.splice(active.indexOf(run), 1);
        const now = Date.now();
        script.cards.forEach(c => { c.run = id; proposed.set(c.id, c); ctx.addCard(c); });
        Object.assign(rec, { status: 'done', ended: now / 1000, durationMs: now - started, answer: script.answer, proposals: script.cards.map(c => c.id) });
        if (script.cards.length) { ctx.log('propose', '제안했어요: ' + script.title + ' · ' + script.cards.length + '개', { origin: 'claude' }); ctx.emitBrain('pending'); }
        emitAI({ type: 'run', runId: id, kind: 'task', status: 'done', text: script.answer });
        emitAI({ type: 'status' });
      });
      return { ok: true, runId: id };
    }
    function aiCancel(p) {
      const i = active.findIndex(r => r.id === p.runId);
      if (i < 0) return { ok: false, error: '돌고 있는 실행이 아니에요' };
      const run = active.splice(i, 1)[0];
      clearTimeout(run.timer); (run.timers || []).forEach(clearTimeout);
      const rec = history.find(h => h.runId === run.id), now = Date.now();
      if (rec) Object.assign(rec, { status: 'cancelled', ended: now / 1000, durationMs: now - run.started, error: { code: 'cancelled', message: '취소했어요.' } });
      emitAI({ type: 'run', runId: run.id, kind: run.kind, status: 'cancelled' });
      emitAI({ type: 'status' });
      return { ok: true };
    }
    // 지난 기록 (처음 한 번만 채운다)
    function seedHistory() {
      if (history.length) return;
      const mk = (ago, o) => Object.assign({ scope: null, prompt: o.title, status: 'done', started: (T0 - ago) / 1000, ended: (T0 - ago) / 1000 + 20, turns: 4, durationMs: 20000, steps: [], answer: '', error: null, proposals: [] }, o);
      history.push(
        mk(3 * HOUR, { runId: 'r_5e1c0a7b9d21', kind: 'task', digestKind: null, title: '정리 안 된 문서 자리 찾기', model: 'opus', durationMs: 41000, turns: 6,
          steps: [{ ts: (T0 - 3 * HOUR) / 1000, kind: 'tool', text: '정리 규칙 확인', tool: 'get_vault_policy', ok: true }, { ts: (T0 - 3 * HOUR) / 1000 + 8, kind: 'tool', text: '정리 안 된 문서 보기', tool: 'list_pending', ok: true },
            { ts: (T0 - 3 * HOUR) / 1000 + 21, kind: 'tool', text: '정리 제안 올리기(2개)', tool: 'propose_changes', ok: true }],
          answer: '정리 안 된 문서 중 **2개**의 자리를 찾아 정리함에 올렸어요.\n\n- [' + t('f4') + '](synapse:doc/f4) → `2-Areas/결제/설계/`\n- [' + t('f5') + '](synapse:doc/f5) → `2-Areas/결제/운영/`' }),
        mk(26 * HOUR, { runId: 'r_b7a41f03c2d8', kind: 'digest', digestKind: 'week', scope: weekScope(0), title: '이번 주 정리', model: 'sonnet', durationMs: 12000, turns: 2 }),
        mk(28 * HOUR, { runId: 'r_90d3e6f1a455', kind: 'task', digestKind: null, title: '쿠폰 정책 관련 결정만 모아서 요약해 줘', model: 'opus', status: 'error', durationMs: 3000, turns: 1,
          error: { code: 'limit', message: AI_ERR.limit } }));
    }
    function aiRuns(p) {
      syncScenario(); seedHistory();
      const lim = Math.max(1, Math.min(200, Number(p && p.limit) || 20));
      return { ok: true, runs: history.slice(0, lim).map(h => {
        const o = { runId: h.runId, kind: h.kind, digestKind: h.digestKind || null, title: h.title, status: h.status, started: h.started, ended: h.ended, model: h.model, durationMs: h.durationMs };
        if (h.error) o.error = h.error.message || String(h.error);
        return o;
      }) };
    }
    function aiRun(p) {
      syncScenario(); seedHistory();
      const h = history.find(x => x.runId === p.runId);
      if (!h) return { ok: false, error: '실행 기록을 찾지 못했어요' };
      const cards = (h.proposals || []).map(id => proposed.get(id)).filter(Boolean);
      return { ok: true, run: { runId: h.runId, kind: h.kind, digestKind: h.digestKind || null, title: h.title, prompt: h.prompt, status: h.status, started: h.started, ended: h.ended, model: h.model, turns: h.turns,
        durationMs: h.durationMs, steps: h.steps, answer: h.answer, error: h.error ? { code: h.error.code, message: h.error.message } : null, proposals: cards } };
    }

    // ----- Jira 제안·반영 -----
    function jiraPropose(p) {
      syncScenario();
      const items = Array.isArray(p.items) ? p.items : [];
      if (!items.length) return { ok: false, error: '올릴 제안이 없어요' };
      const accepted = [], rejected = [];
      items.slice(0, 10).forEach((it, index) => {
        const op = String(it.op || ''), key = String(it.key || '');
        if (['transition', 'comment', 'create'].indexOf(op) < 0) { rejected.push({ index, reason: '알 수 없는 변경이에요: ' + op }); return; }
        if (op !== 'create' && !tk(key)) { rejected.push({ index, reason: key + ' 티켓을 찾지 못했어요' }); return; }
        if (op === 'transition' && !String(it.to || '').trim()) { rejected.push({ index, reason: '바꿀 상태가 비어 있어요' }); return; }
        if (op === 'comment' && (!String(it.body || '').trim() || String(it.body).length > 4000)) { rejected.push({ index, reason: '댓글은 1~4,000자로 써 주세요' }); return; }
        if (op === 'create' && (!String(it.project || '').trim() || !String(it.summary || '').trim())) { rejected.push({ index, reason: '새 티켓에는 프로젝트와 요약이 필요해요' }); return; }
        const same = Array.from(proposed.values()).find(c => c.kind === 'jira' && c.state === 'pending' && c.key === key && c.op === op && (op !== 'transition' || c.to === it.to));
        const card = jiraCard({ op, key: key || (String(it.project) + '-?'), to: it.to, body: it.body, project: it.project, issueType: it.issue_type || it.issueType, summary: it.summary, description: it.description, reason: it.reason }, null);
        if (same) { ctx.removeCard(same.id); proposed.delete(same.id); }
        proposed.set(card.id, card); ctx.addCard(card);
        accepted.push(same ? { index, id: card.id, replaced: true } : { index, id: card.id });
      });
      if (accepted.length) { ctx.log('propose', '제안했어요: Jira ' + accepted.length + '개', { origin: 'claude' }); ctx.emitBrain('pending'); }
      return { ok: accepted.length > 0 || !rejected.length, accepted, rejected };
    }
    function jiraApply(p) {
      syncScenario();
      const c = proposed.get(String(p.id || ''));
      if (!c || c.kind !== 'jira') return aiWait(300).then(() => ({ ok: false, error: '이미 처리한 카드예요' }));
      if (c.state === 'applied' || c.state === 'rejected') return aiWait(300).then(() => ({ ok: false, error: '이미 처리한 카드예요' }));
      if (c.state === 'applying') return aiWait(100).then(() => ({ ok: false, error: '반영하는 중이에요' }));
      if (p.body != null && c.op === 'comment') c.body = String(p.body);
      if (p.to != null && c.op === 'transition') c.to = String(p.to);
      c.state = 'applying'; c.error = null;
      ctx.emitBrain('pending');
      return aiWait(700).then(() => {
        if (window.__MOCK_JIRA_FAIL) {
          if (window.__MOCK_JIRA_FAIL !== 'always') window.__MOCK_JIRA_FAIL = false;
          c.state = 'failed'; c.error = c.op === 'transition' ? '\'' + c.to + '\'(으)로 바꿀 수 없어요. 가능한 상태: 해야 할 일, 진행 중, 완료' : 'Jira에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요';
          ctx.emitBrain('pending');
          return { ok: false, error: c.error };
        }
        c.state = 'applied';
        ctx.removeCard(c.id);
        const message = c.op === 'comment' ? c.key + '에 댓글을 남겼어요' : c.op === 'transition' ? c.key + '을(를) \'' + c.to + '\'(으)로 바꿨어요' : c.key + ' 티켓을 만들었어요';
        ctx.log('apply', 'Jira에 반영했어요: ' + message, { origin: 'claude' });
        ctx.emitBrain('pending');
        return { ok: true, id: c.id, key: c.key, op: c.op, message, url: 'https://your-team.atlassian.net/browse/' + c.key };
      });
    }
    function copyRich(p) {
      // 브라우저 미리보기에서는 글자만 클립보드에 넣어 본다(안 되면 조용히 넘어간다)
      try { if (navigator.clipboard && window.isSecureContext && p && p.text) navigator.clipboard.writeText(String(p.text)).catch(() => {}); } catch (e) { /* 무시 */ }
      return { ok: true };
    }
    const methods = { aiStatus, setAISetting, aiTest, aiDigest, aiTask, aiCancel, aiRuns, aiRun, jiraPropose, jiraApply, copyRich };
    if (ctx.hasTickets) methods.tickets = ticketsCall;
    return {
      methods,
      ticketCounts: () => counts(ticketRows()),
      // 정리함에서 jira 카드를 거절한 경우 기록용
      cardState: (id, state) => { const c = proposed.get(id); if (c) c.state = state; },
      isJira: id => { const c = proposed.get(id); return !!(c && c.kind === 'jira'); },
      // 시나리오 'jira': 정리함에 jira 카드 2장을 미리 올려 둔다
      seedJiraCards: () => [
        jiraCard({ op: 'comment', key: 'CAFE-102', body: '이 티켓이 34일째 진행 중으로 남아 있어요. 로그 보관 기간 조정이 어디까지 진행됐는지 공유해 주실 수 있을까요?', reason: '34일째 갱신이 없어요' }, null),
        jiraCard({ op: 'transition', key: 'CAFE-103', to: '해야 할 일', reason: '9일째 진행 중 표시만 남아 있어요' }, null),
      ].map(c => { proposed.set(c.id, c); return c; }),
    };
  }

  // ===========================================================================
  // v0.9 예시 작업 지도·정리 비서 (docs/V09.md §4.9~§4.11 · §6 · §7.6): workMap · workMapDetail · tidyPlan · tidyDecide · tidyDecideGroup · tidyUndo ·
  // tidyPromote · tidyRules · tidySetRule · tidyRunRules. 명세의 JSON 모양 그대로 흉내 낸다(가상의 데스크톱 예: 티켓 폴더가 아직 없는 산출물, SQL 보고서,
  // 시안 두 벌, .env 알림, 원자료 색인 제외, 오래된 프로젝트 보관, 폴더가 두 곳으로 갈라진 티켓). 파일은 건드리지 않고 상태만 바꾼다.
  // 리뷰 요일 카드를 오늘 바로 보려면 window.__MOCK_REVIEW = true.
  function createTidy(ctx) {
    const T0 = ctx.T0, sc = ctx.sc, t = ctx.t;
    const DESK = '/Users/me/Desktop', VAULT = DESK + '/Vault', CODE = '/Users/me/IdeaProjects';
    const SIGL = {
      'move:ticket-file': '티켓 번호 파일을 티켓 폴더로', 'exclude:raw': '원자료 폴더를 색인에서 빼기', 'move:ticket-new': '티켓 산출물을 새 티켓 폴더로',
      'merge:split': '갈라진 티켓 산출물 합치기', 'archive:stale-project': '30일 넘은 프로젝트 보관', 'archive:done-workspace': '끝난 티켓 폴더 보관',
      'trash:empty': '빈 파일 휴지통으로', 'move:code': '코드 폴더를 코드 폴더로', 'note:secret': '비밀 파일 알림',
      'merge:loose>2-Areas/카페앱': '데스크톱에서 2-Areas › 카페앱으로 합치기', 'merge:loose>1-Projects': '데스크톱에서 1-Projects로 합치기',
      'move:loose>4-Archive': '데스크톱에서 4-Archive로 옮기기', 'trash:loose': '데스크톱 휴지통',
    };
    SIGL['move:code'] = '코드 폴더를 코드 폴더로 옮기기';
    const GROUPS = [['desktop', '데스크톱 정리'], ['tickets', '티켓 폴더'], ['archive', '보관'], ['index', '색인'], ['check', '확인 필요']];
    const REVIEW_DAYS = { mon: ['월요일', 1], tue: ['화요일', 2], wed: ['수요일', 3], thu: ['목요일', 4], fri: ['금요일', 5] };
    const created = label(day0(T0) + 9 * HOUR + 12 * MIN, T0);
    const pLabel = p => {
      const s = String(p);
      if (s === VAULT) return '볼트';
      if (s.indexOf(VAULT + '/') === 0) return s.slice(VAULT.length + 1).split('/').join(' › ');
      if (s.indexOf(CODE) === 0) return '코드 폴더' + (s.length > CODE.length ? ' › ' + s.slice(CODE.length + 1).split('/').join(' › ') : '');
      if (s.indexOf(DESK + '/') === 0) return '데스크톱 › ' + s.slice(DESK.length + 1).split('/').join(' › ');
      return s;
    };
    const fr = (path, isDir, files) => ({ path, label: pLabel(path), isDir: !!isDir, files: files == null ? (isDir ? 0 : 1) : files });

    // 대기 중 정리 제안 (rel = 걸리는 작업 지도 줄 id)
    const SEED = [
      { k: 'a1b2c3d4e5f6', op: 'move', from: [fr(DESK + '/접근성-점검/CAFE-115_접근성_점검표.html', false)], to: VAULT + '/_workspace/CAFE-115', toExists: false,
        title: 'CAFE-115 점검표를 티켓 폴더로', reason: '파일 이름에 CAFE-115가 있는데 티켓 폴더가 아직 없어요', evidence: ['파일 이름에 CAFE-115', '_workspace/CAFE-115 없음', 'Jira: QA 대기'],
        certainty: 'likely', origin: 'rule', sig: 'move:ticket-new', group: 'tickets', impact: { files: 1, links: 0, warnings: [] }, rel: ['t:CAFE-115', 'p:desk-a11y'] },
      { k: '3f2a9c01b7de', op: 'merge', from: [fr(DESK + '/쿠폰-만료-점검', true, 14)], to: VAULT + '/_workspace/CAFE-110', toExists: true,
        title: 'CAFE-110 쿠폰 점검 폴더 합치기', reason: '같은 티켓의 산출물이 데스크톱과 _workspace 두 곳에 있어요', evidence: ['문서 제목에 CAFE-110', '_workspace/CAFE-110 있음', '데스크톱 폴더 10/26 수정'],
        certainty: 'likely', origin: 'rule', sig: 'merge:split', group: 'tickets', impact: { files: 14, links: 3, warnings: ['링크 2개가 바깥 파일을 가리켜요'] }, rel: ['t:CAFE-110', 'p:desk-expiry'] },
      { k: '8c41d7a05e92', op: 'merge', from: [fr(DESK + '/2026-09-매출-분석', true, 8), fr(DESK + '/분석-CSV', true, 5)],
        to: VAULT + '/2-Areas/카페앱/운영/쿼리-모음/2026-09-매출-분석', toExists: false,
        title: 'SQL 보고서 두 폴더를 운영/쿼리-모음으로', reason: '쿼리와 그 결과 CSV라서 한 곳에 있어야 찾기 쉬워요', evidence: ['쿼리와 결과 CSV 이름이 같아요', '운영/쿼리-모음 규칙', '9/9 이후 그대로'],
        certainty: 'likely', origin: 'claude', sig: 'merge:loose>2-Areas/카페앱', group: 'desktop', impact: { files: 13, links: 0, warnings: [] }, rel: ['p:desk-sales', 'p:desk-csv'] },
      { k: '5d09b6c3a8f1', op: 'merge', from: [fr(DESK + '/메뉴판-시안', true, 31), fr(DESK + '/menu-board-drafts', true, 12)], to: VAULT + '/1-Projects/앱-리뉴얼/메뉴판-시안', toExists: false,
        title: '메뉴판 시안 두 벌을 한 프로젝트로', reason: '같은 메뉴판 시안 9개를 두 번 다듬은 폴더예요', evidence: ['같은 시안 9개를 두 번 다듬음', '개인 정리', '9월 이후 그대로'],
        certainty: 'likely', origin: 'claude', sig: 'merge:loose>1-Projects', group: 'desktop', impact: { files: 43, links: 0, warnings: [] }, rel: ['h:menu-board', 'p:desk-menu1', 'p:desk-menu2'] },
      { k: '2e7f10b9c4a3', op: 'move', from: [fr(DESK + '/old-prototype', true, 24)], to: CODE, toExists: true,
        title: '코드 폴더로 옮기기', reason: 'git 저장소라서 볼트 대신 코드 폴더에 두는 게 맞아요', evidence: ['.git 있음', 'package.json 있음', '코드 폴더 ~/IdeaProjects'],
        certainty: 'likely', origin: 'rule', sig: 'move:code', group: 'desktop', impact: { files: 24, links: 0, warnings: [] }, rel: ['p:desk-proto'] },
      { k: '6a53e8d2f0b7', op: 'trash', from: [fr(DESK + '/old-prototype.zip', false)], to: null, toExists: false,
        title: '폴더의 묶음본 zip을 휴지통으로', reason: '같은 이름의 폴더가 있어서 zip은 사본이에요', evidence: ['같은 이름의 폴더가 있어요', '폴더가 더 최근이에요'],
        certainty: 'likely', origin: 'claude', sig: 'trash:loose', group: 'check', impact: { files: 1, links: 0, warnings: [] }, rel: ['p:desk-protozip'] },
      { k: '9b04c7e1d3a6', op: 'move', from: [fr(DESK + '/회의-메모.md', false)], to: VAULT + '/4-Archive/2025-리워드-개편', toExists: false,
        title: '회의-메모.md를 리워드 개편 보관으로', reason: '지난 리워드 개편 회의 기록이라서 지금 쓰는 곳에 둘 필요가 없어요', evidence: ['문서 한 개', '2025 리워드 개편 이야기', '70일째 그대로'],
        certainty: 'likely', origin: 'claude', sig: 'move:loose>4-Archive', group: 'desktop', impact: { files: 1, links: 0, warnings: [] }, rel: ['p:desk-memo'] },
      { k: '4c8a2f6b1e05', op: 'exclude', from: [fr(VAULT + '/_workspace/CAFE-114/results', true, 212)], to: null, toExists: false,
        title: 'CAFE-114 결과 폴더를 색인에서 빼기', reason: 'txt·html 212개가 몰려 있고 문서는 없어요', evidence: ['파일 212개 · 문서 0', '폴더 이름이 results', '출처: 카페앱 _workspace'],
        certainty: 'likely', origin: 'rule', sig: 'exclude:raw', group: 'index', impact: { files: 212, links: 0, warnings: [] }, rel: ['t:CAFE-114', 'p:ws-114'] },
      { k: '7e19d5a0c2b8', op: 'exclude', from: [fr(VAULT + '/1-Projects/앱-리뉴얼/research', true, 468)], to: null, toExists: false,
        title: '앱-리뉴얼 research를 색인에서 빼기', reason: '원자료 txt·html이 몰린 폴더라 검색과 지도에 잡음이 돼요', evidence: ['파일 468개 · 문서 3', '폴더 이름이 research'],
        certainty: 'likely', origin: 'rule', sig: 'exclude:raw', group: 'index', impact: { files: 468, links: 0, warnings: [] }, rel: ['p:proj-renewal'] },
      { k: 'b3d6e9f2a147', op: 'archive', from: [fr(VAULT + '/1-Projects/검색-자동완성', true, 5)], to: VAULT + '/4-Archive/검색-자동완성', toExists: false,
        title: '검색-자동완성을 보관으로', reason: '48일째 그대로이고 열린 티켓도 없어요', evidence: ['48일 그대로', '열린 티켓 없음', '동결 아님'],
        certainty: 'likely', origin: 'rule', sig: 'archive:stale-project', group: 'archive', impact: { files: 5, links: 2, warnings: [] }, rel: ['p:proj-autocomplete'] },
      { k: 'c5f8a1b4d7e2', op: 'archive', from: [fr(VAULT + '/1-Projects/쿠폰-발급', true, 9)], to: VAULT + '/4-Archive/쿠폰-발급', toExists: false,
        title: '쿠폰-발급을 보관으로', reason: '52일째 그대로이고 CAFE-112는 _workspace에서 이어져요', evidence: ['52일 그대로', '열린 티켓 없음'],
        certainty: 'likely', origin: 'rule', sig: 'archive:stale-project', group: 'archive', impact: { files: 9, links: 1, warnings: [] }, rel: ['p:proj-coupon'] },
      { k: 'd1e4b7c0f395', op: 'note', from: [fr(DESK + '/.env', false)], to: null, toExists: false,
        title: '.env 비밀 값 파일 알림', reason: '비밀 값 파일이 데스크톱에 있어요. 필요한 프로젝트로 옮기거나 지워 주세요', evidence: ['이름이 .env', '내용은 열지 않아요'],
        certainty: 'certain', origin: 'rule', sig: 'note:secret', group: 'check', impact: { files: 1, links: 0, warnings: [] }, rel: ['p:desk-env'], canAuto: false },
      { k: 'e8f2a5d9b061', op: 'trash', from: [fr(VAULT + '/무제.canvas', false)], to: null, toExists: false,
        title: '빈 무제 캔버스를 휴지통으로', reason: '내용이 없는 빈 캔버스예요', evidence: ['파일 2바이트', '볼트 루트 낱개 파일'],
        certainty: 'likely', origin: 'rule', sig: 'trash:empty', group: 'check', impact: { files: 1, links: 0, warnings: [] }, rel: ['p:vault-canvas'], canAuto: false },
    ];

    const td = {
      auto: true, cap: 20, codeFolder: '', reviewDay: 'fri', scope: 'all',
      summary: '데스크톱에 업무 산출물이 흩어져 있어요. 티켓 폴더로 모으고, 같은 시안 두 벌과 코드 폴더를 정리하면 데스크톱이 가벼워져요.',
      lastRun: T0 - 62 * MIN, running: false,
      items: sc === 'empty' ? [] : SEED.map(s => Object.assign({}, s, { id: 't:' + s.k, state: 'pending' })),
      batches: [],                        // {id, ids:[item id], auto, ts}
      autoToday: [],
      approvals: { 'move:code': 2, 'merge:loose>2-Areas/카페앱': 3 },
      ruleState: { 'move:ticket-file': 'auto', 'exclude:raw': 'auto', 'merge:loose>2-Areas/카페앱': 'auto', 'move:code': 'ask' },
      prompts: sc === 'empty' ? [] : [{ signature: 'archive:stale-project', label: SIGL['archive:stale-project'], approvals: 3 }],
      questions: sc === 'empty' ? [] : [{ text: 'screenshots 폴더는 어디에 둘까요?', placeId: 'p:ab12cd34ef56', path: DESK + '/screenshots' }],
      seq: 0,
    };
    const stamp = new Date(T0), p2 = n => String(n).padStart(2, '0');
    const batchId = () => 't' + stamp.getFullYear() + p2(stamp.getMonth() + 1) + p2(stamp.getDate()) + p2(stamp.getHours()) + p2(stamp.getMinutes()) + p2(stamp.getSeconds()) + (++td.seq).toString(36).padStart(4, '0');
    if (sc !== 'empty') {
      [['auto-1', 'CAFE-112 초안을 티켓 폴더로', '데스크톱 › CAFE-112-쿠폰-정책-초안.md', '_workspace › CAFE-112', 'move:ticket-file', 4 * HOUR],
       ['auto-2', '앱-리뉴얼/data 색인 제외', '1-Projects › 앱-리뉴얼 › data', '색인에서 뺐어요', 'exclude:raw', 4 * HOUR]].forEach(([id, title, f, to, sig, ago]) => {
        const b = batchId();
        td.batches.push({ id: b, ids: [id], auto: true, ts: T0 - ago });
        td.autoToday.push({ id, title, fromLabel: f, toLabel: to, batchId: b, ts: Math.round((T0 - ago) / 1000), label: label(T0 - ago, T0), undone: false, signature: sig });
      });
    }

    const reviewDue = () => {
      if (td.reviewDay === 'off') return null;
      const d = REVIEW_DAYS[td.reviewDay]; if (!d) return null;
      return window.__MOCK_REVIEW === true || new Date(T0).getDay() === d[1] ? { due: true, day: d[0], label: d[0] + ' 정리 리뷰' } : null;
    };
    const live = () => td.items.filter(i => i.state === 'pending');
    const card = i => ({
      id: i.id, kind: 'tidy', op: i.op, title: i.title, from: i.from.map(f => Object.assign({}, f)),
      to: i.to ? { path: i.to, label: pLabel(i.to), exists: !!i.toExists } : null, reason: i.reason, evidence: i.evidence.slice(), certainty: i.certainty, origin: i.origin,
      originLabel: i.origin === 'claude' ? 'Claude' : '규칙', signature: i.sig, signatureLabel: SIGL[i.sig] || i.sig, group: i.group,
      impact: Object.assign({ files: 0, links: 0, warnings: [] }, i.impact), state: i.state, error: i.error || null, auto: false, createdLabel: created,
      canAuto: i.canAuto !== false && i.op !== 'trash' && i.op !== 'note',
    });
    const counts = () => {
      const pend = live().filter(i => i.op !== 'note');
      const has = s => live().some(i => i.sig === s);
      return { pending: pend.length, autoToday: td.autoToday.filter(a => !a.undone).length, loose: sc === 'empty' ? 0 : 11, inbox: sc === 'empty' ? 0 : 1,
        stale: live().filter(i => i.sig === 'archive:stale-project').length + (sc === 'empty' ? 0 : 2), doneWorkspaces: sc === 'empty' ? 0 : 1,
        raw: live().filter(i => i.op === 'exclude').length, split: live().filter(i => i.sig === 'merge:split').length, secret: has('note:secret') ? 1 : 0 };
    };
    const block = () => ({ pending: counts().pending, autoToday: counts().autoToday, review: reviewDue(), counts: counts() });
    const DEST = [
      [VAULT + '/_workspace/CAFE-110', 'workspace'], [VAULT + '/_workspace/CAFE-112', 'workspace'], [VAULT + '/_workspace/CAFE-111', 'workspace'],
      [VAULT + '/_workspace/CAFE-113', 'workspace'], [VAULT + '/2-Areas/카페앱/운영', 'area'], [VAULT + '/2-Areas/카페앱/운영/쿼리-모음', 'area'],
      [VAULT + '/2-Areas/카페앱/의사결정', 'area'], [VAULT + '/2-Areas/운영', 'area'], [VAULT + '/1-Projects/앱-리뉴얼', 'project'], [VAULT + '/1-Projects/매장-POS-연동', 'project'],
      [VAULT + '/3-Resources/디자인-자료', 'resource'], [VAULT + '/3-Resources/검색', 'resource'], [VAULT + '/4-Archive', 'archive'], [VAULT + '/4-Archive/2025-리워드-개편', 'archive'],
    ].map(([path, zone]) => ({ path, label: pLabel(path), zone })).concat([{ path: CODE, label: '코드 폴더 › IdeaProjects', zone: null }]);

    function plan() {
      const groups = GROUPS.map(([key, title]) => ({ key, title, items: live().filter(i => i.group === key).map(card) })).filter(g => g.items.length);
      const mins = Math.max(1, Math.round((Date.now() - td.lastRun) / MIN));
      return { ok: true, auto: td.auto, summary: sc === 'empty' ? null : td.summary, lastRun: sc === 'empty' ? null : Math.round(td.lastRun / 1000),
        lastRunLabel: sc === 'empty' ? null : mins < 60 ? mins + '분 전' : Math.round(mins / 60) + '시간 전', groups, autoToday: td.autoToday.map(a => Object.assign({}, a)),
        autoUsed: td.autoToday.filter(a => !a.undone).length, autoCap: td.cap, prompts: td.prompts.map(p => Object.assign({}, p)), questions: td.questions.map(q => Object.assign({}, q)),
        review: reviewDue(), counts: counts(), destinations: DEST.map(d => Object.assign({}, d)) };
    }
    function cards() { return live().map(card); }

    function apply(item, to, auto) {
      if (ctx.stopped()) return { fail: '사서가 멈춰 있어서 옮기지 않았어요' };
      if (item.conflict) return { skipped: { title: item.title, reason: item.conflict } };
      if (to) { item.to = to; item.toExists = !!DEST.find(d => d.path === to); }
      item.state = 'applied';
      const b = batchId();
      td.batches.push({ id: b, ids: [item.id], auto: !!auto, ts: Date.now() });
      const dest = item.op === 'exclude' ? '색인에서 뺐어요' : item.op === 'trash' ? 'Synapse 휴지통' : pLabel(item.to || '');
      ctx.log('apply', (auto ? '자동 정리 · ' : '') + (item.op === 'trash' ? '휴지통으로 보냈어요: ' : item.op === 'exclude' ? '색인에서 뺐어요: ' : '옮겼어요: ') + item.title + (item.op === 'move' || item.op === 'merge' || item.op === 'archive' ? ' → ' + dest : ''),
        { batchId: b, undoable: true, origin: item.origin === 'claude' ? 'claude' : 'rules' });
      return { batchId: b };
    }
    function bump(item) {
      td.approvals[item.sig] = (td.approvals[item.sig] || 0) + 1;
      if (td.approvals[item.sig] >= 3 && !td.ruleState[item.sig] && !td.prompts.some(p => p.signature === item.sig)) {
        const pr = { signature: item.sig, label: SIGL[item.sig] || item.sig, approvals: td.approvals[item.sig] };
        td.prompts.push(pr);
        return pr;
      }
      return null;
    }
    function decide(p) {
      const item = td.items.find(i => i.id === p.id && (i.state === 'pending' || i.state === 'later'));
      if (!item) return { ok: false, error: '이미 처리한 제안이에요' };
      const a = p.action;
      if (a === 'reject') { item.state = 'rejected'; ctx.log('reject', '거절했어요: ' + item.title, {}); }
      else if (a === 'later') { item.state = 'later'; }
      else if (a === 'dismiss') { item.state = 'dismissed'; }
      else if (a === 'approve' || a === 'to' || a === 'edit') {
        if (item.op === 'note') return { ok: false, error: '알림은 확인(dismiss)만 할 수 있어요' };
        let to = null;
        if (a !== 'approve') {
          to = String(p.to || '');
          if (!to) return { ok: false, error: '옮길 폴더를 골라 주세요' };
          if (item.op === 'exclude' || item.op === 'trash') return { ok: false, error: '이 제안은 옮길 곳이 없어요' };
          if (item.from.some(f => to === f.path || to.indexOf(f.path + '/') === 0)) return { ok: false, error: '폴더 안으로는 옮길 수 없어요' };
        }
        const r = apply(item, to, false);
        if (r.fail) return { ok: false, error: r.fail };
        if (r.skipped) return { ok: true, applied: { batchId: null, done: 0, skipped: [r.skipped] }, undoable: false, prompt: null };
        const prompt = bump(item);
        ctx.emit('tidy'); ctx.emit('pending'); ctx.emit('home');
        return { ok: true, applied: { batchId: r.batchId, done: 1, skipped: [] }, undoable: true, prompt };
      } else return { ok: false, error: '알 수 없는 동작이에요' };
      ctx.emit('tidy'); ctx.emit('pending'); ctx.emit('home');
      return { ok: true, applied: null, undoable: false, prompt: null };
    }
    function decideGroup(p) {
      const g = String(p.group || '');
      if (!GROUPS.some(x => x[0] === g)) return { ok: false, error: '알 수 없는 묶음이에요' };
      const done = [], skipped = [], batches = [];
      const want = Array.isArray(p.ids) ? new Set(p.ids.map(String)) : null;   // ids가 오면 그 중 아직 대기 중인 것만 승인한다
      live().filter(i => i.group === g && (!want || want.has(i.id))).forEach(i => {
        if (i.certainty === 'unsure' || i.op === 'trash' || i.op === 'note') { skipped.push({ title: i.title, reason: i.op === 'trash' ? '휴지통은 하나씩 확인해요' : i.op === 'note' ? '알림은 확인만 해요' : '확인이 필요한 제안이에요' }); return; }
        const r = apply(i, null, false);
        if (r.fail) { skipped.push({ title: i.title, reason: r.fail }); return; }
        if (r.skipped) { skipped.push(r.skipped); return; }
        done.push(i); batches.push(r.batchId); bump(i);
      });
      ctx.emit('tidy'); ctx.emit('pending'); ctx.emit('home');
      return { ok: true, done: done.length, skipped, batches };
    }
    function undo(p) {
      const bid = p && p.batchId ? p.batchId : (td.batches.length ? td.batches[td.batches.length - 1].id : null);
      const k = bid ? td.batches.findIndex(b => b.id === bid) : -1;
      if (k < 0) return { ok: false, error: '되돌릴 정리가 없어요.' };
      const b = td.batches.splice(k, 1)[0];
      let n = 0;
      b.ids.forEach(id => {
        const it = td.items.find(i => i.id === id);
        if (it) { it.state = 'pending'; n++; }
        const au = td.autoToday.find(a => a.id === id); if (au) { au.undone = true; n++; }
      });
      ctx.log('undo', '되돌렸어요: ' + (b.ids.length > 1 ? b.ids.length + '건' : '정리 1건'), {});
      ctx.emit('tidy'); ctx.emit('pending'); ctx.emit('home');
      return { ok: true, undone: n, conflicts: [] };
    }
    function promote(p) {
      const sig = String(p.signature || '');
      const k = td.prompts.findIndex(x => x.signature === sig);
      if (k >= 0) td.prompts.splice(k, 1);
      td.ruleState[sig] = p.accept ? 'auto' : 'ask';
      ctx.emit('tidy'); ctx.emit('settings');
      return { ok: true };
    }
    function rules() {
      const learnedSigs = Object.keys(td.ruleState).filter(s => s !== 'move:ticket-file' && s !== 'exclude:raw');
      return { auto: td.auto, dailyCap: td.cap, codeFolder: td.codeFolder, codeFolderResolved: td.codeFolder || CODE, reviewDay: td.reviewDay,
        builtin: ['move:ticket-file', 'exclude:raw'].map(s => ({ signature: s, label: SIGL[s], state: td.ruleState[s] || 'auto' })),
        learned: learnedSigs.map(s => ({ signature: s, label: SIGL[s] || s, state: td.ruleState[s], approvals: td.approvals[s] || 0 })) };
    }
    function setRule(p) {
      const sig = String(p.signature || ''), s = String(p.state || '');
      if (['auto', 'ask', 'off'].indexOf(s) < 0) return { ok: false, error: '상태는 auto · ask · off 중 하나예요' };
      td.ruleState[sig] = s;
      td.prompts = td.prompts.filter(x => x.signature !== sig);
      ctx.emit('tidy'); ctx.emit('settings');
      return { ok: true };
    }
    function runRules() {
      if (ctx.stopped()) return { ok: false, error: '사서가 멈춰 있어요. 다시 시작하면 정리할 수 있어요.' };
      ctx.emit('tidy');
      return { ok: true, proposed: 0, applied: 0 };
    }
    function setSetting(k, v) {
      if (k === 'tidy.auto') { if (v !== '0' && v !== '1') return { ok: false, error: '설정 값은 1 또는 0이에요.' }; td.auto = v === '1'; }
      else if (k === 'tidy.dailyCap') { const n = Number(v); if (!(n >= 0 && n <= 200)) return { ok: false, error: '하루 상한은 0~200 사이 숫자예요.' }; td.cap = Math.round(n); }
      else if (k === 'tidy.codeFolder') { if (v && v.charAt(0) !== '/' && v.charAt(0) !== '~') return { ok: false, error: '코드 폴더를 찾을 수 없어요.' }; td.codeFolder = v; }
      else if (k === 'tidy.reviewDay') { if (v !== 'off' && !REVIEW_DAYS[v]) return { ok: false, error: '리뷰 요일은 mon~fri 또는 off예요.' }; td.reviewDay = v; }
      else if (k === 'workmap.scope') { if (['all', 'work', 'personal'].indexOf(v) < 0) return { ok: false, error: '설정 값은 all · work · personal 중 하나예요.' }; td.scope = v; }
      else return null;
      ctx.emit('tidy'); ctx.emit('settings'); ctx.emit('home');
      return { ok: true };
    }
    // Claude 정리 계획이 끝났을 때(aiDigest tidy): 시각을 새로 하고 질문 하나를 더한다
    function planDone() {
      td.lastRun = Date.now(); td.running = false;
      if (sc !== 'empty' && !td.questions.some(q => /coupon-check/.test(q.path))) td.questions.push({ text: 'coupon-check.md는 어느 티켓 폴더에 둘까요?', placeId: 'p:ee34ff56aa78', path: DESK + '/coupon-check.md' });
      ctx.emit('tidy');
    }

    // ---------- 작업 지도 ----------
    const D1 = DAY;
    const wr = (o) => Object.assign({ type: 'ticket', key: null, status: null, statusGroup: 'doing', mine: true, priority: null, dueLabel: null, next: null, nextSource: null,
      lastLabel: '어제', lastTs: Math.round((T0 - D1) / 1000), folders: [], split: false, docs: 0, sessions: 0, docId: null, url: null, scope: 'work', badges: [] }, o);
    const fo = (path, zone, files, lastLabel) => ({ path, label: pLabel(path), zone, files, lastLabel: lastLabel || '어제' });
    const WORK = [
      ['now', wr({ id: 't:CAFE-110', key: 'CAFE-110', title: '쿠폰 만료 처리 점검', status: '진행 중', priority: 'High', dueLabel: '3일 남음',
        next: '만료 전환 점검 쿼리 정리', nextSource: 'claude', folders: [fo(DESK + '/쿠폰-만료-점검', 'loose', 14, '10/26'), fo(VAULT + '/_workspace/CAFE-110', 'workspace', 9, '어제')], split: true,
        docs: 4, sessions: 2, docId: 'f1', url: 'https://your-team.atlassian.net/browse/CAFE-110', badges: ['split', 'due'] })],
      ['now', wr({ id: 't:CAFE-111', key: 'CAFE-111', title: '픽업 준비 알림 문구 정리', status: '진행 중', priority: 'Medium', next: '문구 후보 3개 비교', nextSource: 'thread', lastLabel: '2일 전',
        lastTs: Math.round((T0 - 2 * D1) / 1000), folders: [fo(VAULT + '/_workspace/CAFE-111', 'workspace', 5, '2일 전')], docs: 2, sessions: 1, docId: 'f3', url: 'https://your-team.atlassian.net/browse/CAFE-111' })],
      ['now', wr({ id: 'h:menu-board', type: 'thread', title: '메뉴판 시안 비교', status: null, statusGroup: 'doing', mine: true, scope: 'personal', next: '시안 9개 비교표 만들기', nextSource: 'thread',
        lastLabel: '3일 전', lastTs: Math.round((T0 - 3 * D1) / 1000), folders: [fo(DESK + '/메뉴판-시안', 'loose', 31, '3일 전'), fo(DESK + '/menu-board-drafts', 'loose', 12, '3일 전')], split: true, docs: 6, sessions: 3, docId: 'p4', badges: ['split'] })],
      ['next', wr({ id: 't:CAFE-113', key: 'CAFE-113', title: '이벤트 배너 노출 순서 정하기', status: '해야 할 일', statusGroup: 'todo', priority: 'Medium', dueLabel: '5일 남음',
        next: '명세(CAFE-116)부터 정리', nextSource: 'claude', lastLabel: '2일 전', lastTs: Math.round((T0 - 2 * D1) / 1000), folders: [], docs: 2, docId: 'f5', url: 'https://your-team.atlassian.net/browse/CAFE-113', badges: ['due'] })],
      ['next', wr({ id: 't:CAFE-112', key: 'CAFE-112', title: '쿠폰 정책 초안 정리', status: '해야 할 일', statusGroup: 'todo', priority: 'High', next: '발급 대상 조건 표 마무리', nextSource: 'thread',
        lastLabel: '오늘', folders: [fo(VAULT + '/_workspace/CAFE-112', 'workspace', 3, '오늘')], docs: 3, docId: 'f2', url: 'https://your-team.atlassian.net/browse/CAFE-112' })],
      ['next', wr({ id: 't:CAFE-114', key: 'CAFE-114', title: '검색 자동완성 개선 검토 · 로그 조사', status: '해야 할 일', statusGroup: 'todo', mine: true, next: null,
        lastLabel: '5일 전', lastTs: Math.round((T0 - 5 * D1) / 1000), folders: [fo(VAULT + '/_workspace/CAFE-114', 'workspace', 231, '5일 전')], docs: 3, docId: 's1', url: 'https://your-team.atlassian.net/browse/CAFE-114' })],
      ['waiting', wr({ id: 't:CAFE-115', key: 'CAFE-115', title: '접근성 개선: 주문 화면 읽기 순서', status: 'QA 대기', statusGroup: 'waiting', priority: 'Medium', next: null, lastLabel: '6일 전',
        lastTs: Math.round((T0 - 6 * D1) / 1000), folders: [fo(DESK + '/접근성-점검', 'loose', 6, '9일 전')], docs: 2, docId: 'f4', url: 'https://your-team.atlassian.net/browse/CAFE-115', badges: ['stale'] })],
    ];
    const pr = (o) => Object.assign({ type: 'place', name: '', label: '', path: '', zone: 'project', health: 'fresh', healthLabel: '', files: 0, md: 0, lastLabel: '', lastTs: 0, tickets: [], flags: [], docId: null, scope: 'work' }, o);
    const ago = d => ({ lastLabel: d <= 0 ? '오늘' : d === 1 ? '어제' : d + '일 전', lastTs: Math.round((T0 - d * D1) / 1000) });
    const PLACES = [
      ['areas', pr(Object.assign({ id: 'p:area-cafe', name: '카페앱', label: '2-Areas › 카페앱', path: VAULT + '/2-Areas/카페앱', zone: 'area', health: 'fresh', healthLabel: '이번 주 +7', files: 432, md: 410, tickets: ['CAFE-110', 'CAFE-115'], docId: 'f1' }, ago(1)))],
      ['areas', pr(Object.assign({ id: 'p:area-ops', name: '운영', label: '2-Areas › 운영', path: VAULT + '/2-Areas/운영', zone: 'area', health: 'warm', healthLabel: '12일 전', files: 128, md: 120, docId: 'f2' }, ago(12)))],
      ['projects', pr(Object.assign({ id: 'p:proj-pos', name: '매장-POS-연동', label: '1-Projects › 매장-POS-연동', path: VAULT + '/1-Projects/매장-POS-연동', health: 'fresh', healthLabel: '어제', files: 86, md: 60, docId: 'p2' }, ago(1)))],
      ['projects', pr(Object.assign({ id: 'p:proj-menu', name: '메뉴-추천', label: '1-Projects › 메뉴-추천', path: VAULT + '/1-Projects/메뉴-추천', health: 'fresh', healthLabel: '3일 전', files: 41, md: 38, docId: 'i2' }, ago(3)))],
      ['projects', pr(Object.assign({ id: 'p:proj-renewal', name: '앱-리뉴얼', label: '1-Projects › 앱-리뉴얼', path: VAULT + '/1-Projects/앱-리뉴얼', health: 'messy', healthLabel: '원자료 2곳', files: 630, md: 12, flags: ['raw'], docId: 'p3' }, ago(6)))],
      ['projects', pr(Object.assign({ id: 'p:proj-autocomplete', name: '검색-자동완성', label: '1-Projects › 검색-자동완성', path: VAULT + '/1-Projects/검색-자동완성', health: 'stale', healthLabel: '48일 그대로', files: 5, md: 4, docId: 's3' }, ago(48)))],
      ['projects', pr(Object.assign({ id: 'p:proj-coupon', name: '쿠폰-발급', label: '1-Projects › 쿠폰-발급', path: VAULT + '/1-Projects/쿠폰-발급', health: 'stale', healthLabel: '52일 그대로', files: 9, md: 9, docId: 'f2' }, ago(52)))],
      ['projects', pr(Object.assign({ id: 'p:proj-design', name: '카페앱-설계', label: '1-Projects › 카페앱-설계', path: VAULT + '/1-Projects/카페앱-설계', health: 'frozen', healthLabel: '동결, 참조용', files: 214, md: 200, flags: ['frozen'], docId: 'f1' }, ago(42)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-expiry', name: '쿠폰-만료-점검', label: '데스크톱 › 쿠폰-만료-점검', path: DESK + '/쿠폰-만료-점검', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 12일째', files: 14, md: 3, tickets: ['CAFE-110'] }, ago(1)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-a11y', name: '접근성-점검', label: '데스크톱 › 접근성-점검', path: DESK + '/접근성-점검', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 9일째', files: 6, md: 0, tickets: ['CAFE-115'] }, ago(9)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-sales', name: '2026-09-매출-분석', label: '데스크톱 › 2026-09-매출-분석', path: DESK + '/2026-09-매출-분석', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 48일째', files: 8, md: 1 }, ago(48)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-csv', name: '분석-CSV', label: '데스크톱 › 분석-CSV', path: DESK + '/분석-CSV', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 48일째', files: 5, md: 0 }, ago(48)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-menu1', name: '메뉴판-시안', label: '데스크톱 › 메뉴판-시안', path: DESK + '/메뉴판-시안', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 30일째', files: 31, md: 9, scope: 'personal' }, ago(30)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-menu2', name: 'menu-board-drafts', label: '데스크톱 › menu-board-drafts', path: DESK + '/menu-board-drafts', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 30일째', files: 12, md: 9, scope: 'personal' }, ago(30)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-proto', name: 'old-prototype', label: '데스크톱 › old-prototype', path: DESK + '/old-prototype', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 21일째', files: 24, md: 1, flags: ['git', 'code'], scope: 'personal' }, ago(21)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-protozip', name: 'old-prototype.zip', label: '데스크톱 › old-prototype.zip', path: DESK + '/old-prototype.zip', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 21일째', files: 1, md: 0, scope: 'personal' }, ago(21)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-env', name: '.env', label: '데스크톱 › .env', path: DESK + '/.env', zone: 'loose', health: 'messy', healthLabel: '비밀 파일', files: 1, md: 0, flags: ['secret', 'hidden'] }, ago(40)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-memo', name: '회의-메모.md', label: '데스크톱 › 회의-메모.md', path: DESK + '/회의-메모.md', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 70일째', files: 1, md: 1 }, ago(70)))],
      ['unfiled', pr(Object.assign({ id: 'p:desk-shots', name: 'screenshots', label: '데스크톱 › screenshots', path: DESK + '/screenshots', zone: 'loose', health: 'messy', healthLabel: '데스크톱에 18일째', files: 37, md: 0 }, ago(18)))],
      ['unfiled', pr(Object.assign({ id: 'p:inbox-todo', name: '할일-메모.md', label: '_Inbox › 할일-메모.md', path: VAULT + '/_Inbox/할일-메모.md', zone: 'inbox', health: 'messy', healthLabel: '받은 문서함에 62일째', files: 1, md: 1, docId: 'i3' }, ago(62)))],
      ['unfiled', pr(Object.assign({ id: 'p:vault-canvas', name: '무제.canvas', label: '볼트 루트 › 무제.canvas', path: VAULT + '/무제.canvas', zone: 'vault-root', health: 'messy', healthLabel: '빈 파일', files: 1, md: 0, flags: ['empty'] }, ago(33)))],
      ['resources', pr(Object.assign({ id: 'p:res-design', name: '디자인-자료', label: '3-Resources › 디자인-자료', path: VAULT + '/3-Resources/디자인-자료', zone: 'resource', health: 'warm', healthLabel: '20일 전', files: 52, md: 52, docId: 's2' }, ago(20)))],
      ['resources', pr(Object.assign({ id: 'p:res-search', name: '검색', label: '3-Resources › 검색', path: VAULT + '/3-Resources/검색', zone: 'resource', health: 'stale', healthLabel: '95일 그대로', files: 18, md: 18, docId: 's4' }, ago(95)))],
      ['archive', pr(Object.assign({ id: 'p:arc-reward', name: '2025-리워드-개편', label: '4-Archive › 2025-리워드-개편', path: VAULT + '/4-Archive/2025-리워드-개편', zone: 'archive', health: 'stale', healthLabel: '210일 그대로', files: 77, md: 70, docId: 'f4' }, ago(210)))],
    ];
    const SECTIONS = [['now', '지금'], ['next', '다음'], ['waiting', '기다림'], ['areas', '영역'], ['projects', '프로젝트'], ['unfiled', '정리 안 됨'], ['resources', '자료'], ['archive', '보관']];
    const propsOf = id => live().filter(i => (i.rel || []).indexOf(id) >= 0);
    function workMap() {
      if (sc === 'empty') {
        return { ok: true, generated: Math.round(T0 / 1000), hasJira: false, scope: td.scope, tidy: { pending: 0, autoToday: 0, lastRunLabel: null, review: null, counts: counts() },
          sections: SECTIONS.map(([key, title]) => ({ key, title, items: [] })), empty: '자료를 연결하면 여기에 할 일과 폴더가 정리돼요' };
      }
      const ok = r => td.scope === 'all' || r.scope === td.scope;
      const mins = Math.max(1, Math.round((Date.now() - td.lastRun) / MIN));
      const sections = SECTIONS.map(([key, title]) => {
        const items = WORK.concat(PLACES).filter(x => x[0] === key).map(x => Object.assign({}, x[1])).filter(ok)
          .map(r => Object.assign(r, { proposals: propsOf(r.id).length }));
        const o = { key, title, items };
        if (key === 'resources' || key === 'archive') o.collapsed = true;
        return o;
      });
      return { ok: true, generated: Math.round(Date.now() / 1000), hasJira: true, scope: td.scope,
        tidy: { pending: counts().pending, autoToday: counts().autoToday, lastRunLabel: mins < 60 ? mins + '분 전' : Math.round(mins / 60) + '시간 전', review: reviewDue(), counts: counts() }, sections, empty: null };
    }
    const FACTS = {
      't:CAFE-110': ['담당 나', '우선순위 High', '10/20부터 진행 중', '마지막 갱신 어제'], 't:CAFE-111': ['담당 나', '우선순위 Medium', '10/22부터 진행 중', '마지막 갱신 2일 전'],
      't:CAFE-113': ['담당 나', '우선순위 Medium', '기한 5일 남음'], 't:CAFE-112': ['담당 나', '우선순위 High', '마지막 갱신 오늘'],
      't:CAFE-114': ['담당 나', '마지막 갱신 5일 전'], 't:CAFE-115': ['담당 나', 'QA 대기 6일', '우선순위 Medium'], 'h:menu-board': ['개인 정리', '세션 3개', '마지막 활동 3일 전'],
    };
    const SUMMARY = {
      't:CAFE-110': '쿠폰 만료 처리 방식을 새 기준으로 바꾸기 전에 마지막으로 점검하는 단계예요.',
      't:CAFE-111': '픽업 준비 알림에 들어가는 문구를 짧고 분명하게 다듬는 작업이에요.', 't:CAFE-113': '홈 화면 이벤트 배너가 어떤 순서로 보일지 정해요.',
      't:CAFE-112': '쿠폰을 누구에게 언제 발급하고 언제 만료할지 정책 초안을 문서로 남겨요.', 't:CAFE-115': '주문 화면의 읽기 순서를 고치는 접근성 개선이 QA를 기다리고 있어요.',
      'h:menu-board': '같은 메뉴판 시안 9개를 두 폴더에서 따로 다듬은 흐름이에요.',
    };
    const DOCS = { 't:CAFE-110': ['f1', 'f2', 'f4', 's1'], 't:CAFE-111': ['f3', 's2'], 't:CAFE-113': ['f5', 's3'], 't:CAFE-112': ['f2', 'f3', 'f4'], 't:CAFE-114': ['s1', 's2', 's5'], 't:CAFE-115': ['f4', 'p3'], 'h:menu-board': ['p4', 'p5', 'i4'] };
    function detail(p) {
      const id = String(p.id || '');
      const w = WORK.find(x => x[1].id === id), pl = PLACES.find(x => x[1].id === id);
      if (!w && !pl) return { ok: false, error: '이 항목을 찾지 못했어요' };
      const props = propsOf(id).map(card);
      if (w) {
        const r = w[1];
        const docs = (DOCS[id] || []).map((d, i) => ({ docId: d, title: t(d), label: i % 2 ? 'Confluence' : '볼트 노트', lastLabel: agoWord(i) }));
        return { ok: true, id, type: r.type, title: r.title, key: r.key, status: r.status, url: r.url, docId: r.docId, summary: SUMMARY[id] || null, next: r.next,
          facts: FACTS[id] || [], folders: r.folders.map(f => Object.assign({}, f)), docs, sessions: r.sessions ? [{ title: '만료 쿼리 점검', lastLabel: '어제' }, { title: '만료 안내 문구 정리', lastLabel: '3일 전' }].slice(0, r.sessions) : [],
          children: [], proposals: props, graphDocId: r.docId };
      }
      const r = pl[1], kids = r.zone === 'loose' || r.files < 6 ? [] : [{ name: '운영', files: 54, lastLabel: '어제' }, { name: 'ADR', files: 90, lastLabel: '3일 전' }, { name: '기술노트', files: 32, lastLabel: '12일 전' }];
      return { ok: true, id, type: 'place', title: r.name, key: null, status: null, url: null, docId: r.docId, summary: r.health === 'frozen' ? '스스로 동결, 참조용이라고 적힌 프로젝트라 보관 제안은 하지 않아요.' : null, next: null,
        facts: ['파일 ' + r.files + '개 · 문서 ' + r.md + '개', '마지막 수정 ' + r.lastLabel, r.healthLabel].concat(r.tickets.length ? ['티켓 ' + r.tickets.join(', ')] : []),
        folders: [{ path: r.path, label: pLabel(r.path), zone: r.zone, files: r.files, lastLabel: r.lastLabel }],
        docs: r.docId ? [{ docId: r.docId, title: t(r.docId), label: '볼트 노트', lastLabel: r.lastLabel }] : [], sessions: [], children: kids, proposals: props, graphDocId: r.docId };
    }

    const methods = {
      workMap, workMapDetail: detail, tidyPlan: plan, tidyDecide: decide, tidyDecideGroup: decideGroup, tidyUndo: undo,
      tidyPromote: promote, tidyRules: rules, tidySetRule: setRule, tidyRunRules: runRules,
    };
    return { methods, cards, counts, block, rules, setSetting, planDone, scope: () => td.scope, isTidyBatch: b => /^t2/.test(String(b || '')), undo, summary: () => td.summary };
  }

  function create(docsIn, opts) {
    opts = opts || {};
    const sc = opts.scenario || 'full';
    const emit = typeof opts.emit === 'function' ? opts.emit : () => {};
    let hasTickets = false, ai = null;   // v0.8: 아래 METHODS 앞에서 채운다
    const base = (window.SYNAPSE_DATA && window.SYNAPSE_DATA.docs) || [];
    const titles = new Map(base.map(d => [d.id, d.title]));
    (docsIn || []).forEach(d => { if (d && d.id != null) titles.set(String(d.id), d.title || titles.get(String(d.id))); });
    const t = id => titles.get(id) || id;
    const st = {
      sessions: sc === 'sessions' || sc === 'empty' ? null : true, requestText: true, cleared: false,
      stopped: sc === 'stopped', remoteBodies: false, approved: false,
      pins: new Set(), demoted: new Map(), woken: new Set(), names: new Map(), batches: [], log: [], logNo: 0, batchNo: 0,
    };
    const T0 = Date.now();
    const yAt = (h, m) => day0(T0) - DAY + h * HOUR + m * MIN;   // 어제 h:m
    // 흐름 정의 (점수 순 = 지도 색 순서). 코드 흐름(t3)은 세션 기록이 켜져 있을 때만 생긴다.
    const THREADS = [
      { tid: 't1', title: '결제 · 정산 흐름', docs: ['f1', 'f2', 'f4'], primary: 'f1', tier: 'now', project: '결제', type: '설계', heading: '확인할 것', line: 5,
        open: 3, done: 2, actor: 'human', when: yAt(18, 40), bright: 1,
        chips: [{ text: '어제 내가 수정', kind: 'activity' }, { text: '할 일 3', kind: 'task' }, { ask: true }],
        ask: { tool: 'claude', text: '정산 대시보드 카드 순서를 기획안대로 바꿔 줘', ago: 95 * MIN, outputs: 1 }, outputs: ['f4'],
        why: [{ text: '어제 18:40 내가 수정', detail: '정산 흐름 정리 · ‘확인할 것’', docId: 'f1', line: 5 }, { text: '열린 할 일 3', detail: '정산 흐름 정리 7행', docId: 'f1', line: 7 },
          { text: '데일리에 나옴', detail: '어제 데일리 노트 3행', docId: 'f2', line: 3 }] },
      { tid: 't2', title: '검색 · 인덱스 설계', docs: ['s1', 's2', 's5'], primary: 's1', tier: 'week', project: '검색', type: 'TN', heading: null, line: 3,
        open: 2, done: 1, actor: 'mixed', when: day0(T0) - 2 * DAY + 11 * HOUR + 20 * MIN, due: day0(T0) + 5 * DAY, bright: 0.8,
        chips: [{ text: '기한 D-5', kind: 'due' }, { text: '이번 주 3번 열람', kind: 'activity' }, { text: '할 일 2', kind: 'task' }],
        why: [{ text: '체크박스 기한 D-5', detail: '로컬 검색 인덱스 설계 3행', docId: 's1', line: 3 }, { text: '이번 주 3번 열람', detail: '옵시디언에서 연 기록', docId: 's1', line: null }] },
      { tid: 't3', code: { repo: 'synapse', branch: 'feat/home', cwd: '~/work/synapse' }, title: 'synapse · feat/home', sessionTitle: '홈 화면 v0.5', docs: ['s4'], primary: null,
        tier: 'week', actor: 'codex', when: T0 - 3 * HOUR, bright: 0.9, open: 0, done: 0,
        chips: [{ ask: true }, { text: '오늘 파일 4개 작성', kind: 'activity', source: 'codex' }],
        ask: { tool: 'codex', text: '홈 화면 줄 형식을 명세대로 맞춰 줘', ago: 3 * HOUR, outputs: 2 }, outputs: ['s4', 'i1'], sessionsOnly: true,
        why: [{ text: 'Codex에게 요청', detail: '세션 ‘홈 화면 v0.5’', docId: null, line: null }, { text: 'AI가 쓴 문서 2개', detail: '문서 연결 그래프 실험 외 1', docId: 's4', line: null }] },
      { tid: 't4', title: '고객 이탈 가설', docs: ['p4', 'p1', 'p5'], primary: 'p4', tier: 'none', project: '제품', type: '기타', heading: null, line: 1,
        open: 1, done: 0, actor: 'human', when: T0 - 3 * DAY - 2 * HOUR, bright: 0.6,
        chips: [{ text: '3일 전 내가 수정', kind: 'activity' }, { text: '들어오는 링크 4', kind: 'link' }],
        why: [{ text: '3일 전 내가 수정', detail: '고객 이탈 원인 가설', docId: 'p4', line: 1 }, { text: '들어오는 링크 4', detail: '고객 인터뷰 발췌 외 3', docId: 'p1', line: null }] },
      { tid: 't5', title: '제품 탐색 경험', docs: ['p2'], primary: 'p2', tier: 'none', project: '제품', line: 1, open: 0, done: 0, actor: 'human', when: T0 - 6 * DAY, bright: 0.4,
        chips: [{ text: '6일 전 열람', kind: 'activity' }], why: [{ text: '6일 전 열람', detail: '제품 탐색 경험 개선', docId: 'p2', line: null }] },
      { tid: 't6', title: '디지털 정원', docs: ['i2', 'i5'], primary: 'i2', tier: 'dormant', project: '아이디어', line: 1, open: 2, done: 0, actor: 'human', when: T0 - 19 * DAY, bright: 0.15,
        chips: [{ text: '19일 동안 조용해요', kind: 'activity' }, { text: '할 일 2', kind: 'task' }], why: [{ text: '마지막 사람 활동 19일 전', detail: '디지털 정원 스케치', docId: 'i2', line: null }] },
      { tid: 't7', title: '단축키 런처', docs: ['i3'], primary: 'i3', tier: 'dormant', line: 1, open: 0, done: 0, actor: 'claude', when: T0 - 24 * DAY, bright: 0.15,
        chips: [{ text: '24일 동안 조용해요', kind: 'activity' }], why: [{ text: '마지막 사람 활동 24일 전', detail: '단축키 런처 스케치', docId: 'i3', line: null }] },
      { tid: 't8', title: '숫자에서 문서로', docs: ['i4', 'p3'], primary: 'i4', tier: 'dormant', line: 1, open: 1, done: 3, actor: 'human', when: T0 - 31 * DAY, bright: 0.15,
        chips: [{ text: '한 달 동안 조용해요', kind: 'activity' }], why: [{ text: '마지막 사람 활동 31일 전', detail: '숫자에서 문서로', docId: 'i4', line: null }] },
      { tid: 't9', title: '연결형 검색 메모', docs: ['i1'], primary: 'i1', tier: 'none', line: 1, open: 0, done: 0, actor: 'claude', when: T0 - 9 * DAY, bright: 0.3,
        chips: [{ text: '9일 전 Claude가 작성', kind: 'activity', source: 'claude' }], why: [{ text: 'Claude가 작성', detail: '연결형 검색 아이디어', docId: 'i1', line: null }] },
    ];
    const URGENT = [
      { id: 'task:u1', kind: 'task', title: '환불 안내 문구 확정', docId: 'f3', line: 5, due: day0(T0), project: '결제', actor: 'human', when: yAt(10, 5),
        chips: [{ text: '기한 오늘', kind: 'due' }, { text: '중요 표시', kind: 'task' }], heading: '고객 안내',
        why: [{ text: '체크박스 기한 오늘', detail: '환불 예외 처리 메모 5행', docId: 'f3', line: 5 }, { text: '중요 표시 ⏫', detail: '같은 줄', docId: 'f3', line: 5 }] },
      { id: 'task:u2', kind: 'issue', title: 'PAY-147 · 중복 요청 방지 체크', docId: 'f5', line: null, due: day0(T0) + DAY, project: 'PAY', actor: null, when: null,
        chips: [{ text: '기한 내일', kind: 'due' }, { text: 'PAY-147 진행 중', kind: 'jira' }, { text: '내 담당 High', kind: 'jira' }],
        why: [{ text: 'Jira 기한 내일', detail: 'PAY-147', docId: 'f5', line: null }, { text: '내 담당 · 진행 중', detail: 'Jira 상태 변화 어제 17:02', docId: 'f5', line: null }] },
    ];
    const sessionsOn = () => st.sessions === true && !st.cleared;
    const threadsNow = () => THREADS.filter(x => !x.sessionsOnly || sessionsOn());
    const chipsOf = x => {
      const out = [];
      if (st.pins.has('thread:t:' + x.tid) || st.pins.has(x.id)) out.push({ text: '항상 위', kind: 'pin', source: 'rules' });
      if (x.tid && st.woken.has(x.tid)) out.push({ text: '방금 깨웠어요', kind: 'activity', source: 'rules' });
      (x.chips || []).forEach(c => {
        if (c.ask) { if (sessionsOn() && x.ask) out.push({ text: (x.ask.tool === 'codex' ? 'Codex' : 'Claude') + '에게 ' + hm(T0 - x.ask.ago) + ' 요청', kind: 'session', source: x.ask.tool }); return; }
        if (c.source && c.source !== 'rules' && !sessionsOn() && c.kind === 'activity') return;
        out.push({ text: c.text, kind: c.kind, source: c.source || 'rules' });
      });
      return out.slice(0, 3);
    };
    const actorOf = x => (!sessionsOn() && (x.actor === 'claude' || x.actor === 'codex' || x.actor === 'mixed')) ? (x.code ? null : 'human') : x.actor;
    function threadItem(x) {
      const a = actorOf(x), ask = sessionsOn() && x.ask ? x.ask : null;
      const tier = x.tier === 'dormant' && st.woken.has(x.tid) ? 'week' : x.tier;
      return {
        id: 'thread:t:' + x.tid, kind: 'thread', title: st.names.get('thread:t:' + x.tid) || x.title, docId: x.primary || null, line: x.line || null, tier,
        when: x.when ? new Date(x.when).toISOString() : null, whenLabel: x.when ? label(x.when, T0) : null,
        actor: a || null, actorLabel: a ? ACTOR[a] : null,
        stopped: x.primary ? { heading: x.heading || null, line: x.line || 1 } : null,
        openTasks: x.open || 0, doneTasks: x.done || 0,
        due: x.due ? ymd(x.due) : null, dueLabel: x.due ? dueLabel(x.due, T0) : null,
        lastAsk: ask ? { tool: ask.tool, text: st.requestText ? ask.text : null, at: new Date(T0 - ask.ago).toISOString(), atLabel: hm(T0 - ask.ago), outputs: ask.outputs } : null,
        project: x.project || null, type: x.type || null, chips: chipsOf(x), source: 'rules', pinned: st.pins.has('thread:t:' + x.tid),
        summary: x.primary ? firstSentence(x.primary) : null, summarySource: x.primary ? 'first' : null,
        sessionTitle: sessionsOn() ? x.sessionTitle || null : null, code: x.code || null,
        outputs: sessionsOn() ? (x.outputs || []).map(id => ({ docId: id, title: t(id) })) : [],
      };
    }
    function urgentItem(u) {
      return { id: u.id, kind: u.kind, title: u.title, docId: u.docId, line: u.line, tier: 'now', when: u.when ? new Date(u.when).toISOString() : null,
        whenLabel: u.when ? label(u.when, T0) : null, actor: u.actor, actorLabel: u.actor ? ACTOR[u.actor] : null,
        stopped: u.heading ? { heading: u.heading, line: u.line } : null, openTasks: 1, doneTasks: 0, due: ymd(u.due), dueLabel: dueLabel(u.due, T0),
        lastAsk: null, project: u.project, type: null, chips: chipsOf(u), source: 'rules', pinned: st.pins.has(u.id), summary: null, summarySource: null,
        sessionTitle: null, code: null, outputs: [] };
    }
    function firstSentence(id) {
      const d = base.find(x => x.id === id);
      const p = d && d.body && d.body[0] ? String(d.body[0]) : '';
      const m = p.match(/^.*?[.?!。](\s|$)/);
      return (m ? m[0] : p).trim().slice(0, 80) || null;
    }
    const demotedNow = id => st.demoted.has(id);
    function home() {
      const lib = { newDocs: sc === 'empty' ? 0 : 5, inPlace: sc === 'empty' ? 0 : 3, pending: pendingCount(), engine: 'rules', engineLabel: '규칙',
        stopped: st.stopped, lastBatchLabel: sc === 'empty' ? null : '오늘 ' + (new Date(T0).getHours() >= 12 ? '12:00' : '09:00') };
      const sessions = { enabled: st.sessions, askCard: st.sessions == null };
      if (sc === 'empty') return { generatedAt: new Date().toISOString(), urgent: [], current: null, next: [], dormant: { count: 0, items: [] }, oldTasks: 0, librarian: lib, sessions, empty: true, tidy: tidy.block() };
      const all = threadsNow().map(threadItem);
      const live = all.filter(i => i.tier !== 'dormant' && !demotedNow(i.id));
      const cur = live.find(i => i.id === 'thread:t:t1') || live[0] || null;
      const rest = live.filter(i => i !== cur).sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0));
      const dorm = all.filter(i => i.tier === 'dormant');
      return { generatedAt: new Date().toISOString(), urgent: URGENT.filter(u => !demotedNow(u.id)).map(urgentItem), current: cur, next: rest.slice(0, 3),
        dormant: { count: dorm.length, items: dorm.slice(0, 5) }, oldTasks: 4, librarian: lib, sessions, empty: false,
        tickets: hasTickets ? ai.ticketCounts() : undefined, tidy: tidy.block() };
    }
    function why(id) {
      const src = THREADS.find(x => 'thread:t:' + x.tid === id) || URGENT.find(u => u.id === id);
      if (!src) return { ok: false, error: '이 항목을 찾지 못했어요' };
      const item = src.tid ? threadItem(src) : urgentItem(src);
      const reasons = (src.why || []).filter(r => !(src.sessionsOnly && !sessionsOn())).map(r => Object.assign({ source: 'rules' }, r));
      if (item.lastAsk) reasons.push({ text: (item.lastAsk.tool === 'codex' ? 'Codex' : 'Claude') + '에게 ' + item.lastAsk.atLabel + ' 요청', detail: item.lastAsk.text ? '“' + item.lastAsk.text + '”' : '세션 기록', docId: null, line: null, source: item.lastAsk.tool });
      if (item.pinned) reasons.unshift({ text: '항상 위로 고정했어요', detail: '내 교정', docId: null, line: null, source: 'rules' });
      const actions = [item.pinned ? { id: 'unpin', label: '고정 풀기' } : { id: 'pin', label: '항상 위' }, { id: 'demote', label: '덜 중요' }];
      if (src.tier === 'dormant') actions.push({ id: 'wake', label: '깨우기' });
      if (src.tid) actions.push({ id: 'rename', label: '이름 바꾸기' });
      return { id, title: item.title, tier: item.tier, tierLabel: TIER[item.tier] || '', reasons: reasons.slice(0, 8), actions };
    }
    function feedback(p) {
      const id = String(p.id || ''), a = p.action;
      if (!id) return { ok: false, error: '항목이 없어요' };
      if (a === 'pin') st.pins.add(id);
      else if (a === 'unpin') st.pins.delete(id);
      else if (a === 'demote') { st.demoted.set(id, p.scope === 'always' ? 'always' : 'week'); st.pins.delete(id); }
      else if (a === 'wake') { st.woken.add(id.replace(/^thread:t:/, '')); st.demoted.delete(id); }
      else if (a === 'rename') { const v = String(p.scope || '').trim(); if (!v) return { ok: false, error: '이름이 비어 있어요' }; st.names.set(id, v.slice(0, 60)); }
      else return { ok: false, error: '알 수 없는 동작이에요' };
      emit('home');
      return { ok: true };
    }
    function map() {
      const list = threadsNow();
      const threads = list.map((x, i) => ({ id: 't:' + x.tid, title: st.names.get('thread:t:' + x.tid) || x.title,
        tier: x.tier === 'dormant' && st.woken.has(x.tid) ? 'week' : x.tier, colorIndex: i < 8 ? i : -1, brightness: x.bright, docIds: x.docs.slice(),
        lastLabel: x.when ? label(x.when, T0) : null, openTasks: x.open || 0, primaryDocId: x.primary || x.docs[0] || null }));
      const docThread = {};
      threads.forEach(th => th.docIds.forEach(d => { if (!docThread[d]) docThread[d] = th.id; }));
      const dim = [];
      threads.forEach(th => { if (th.tier === 'dormant') dim.push(...th.docIds); });
      return { threads, docThread, hiddenArchive: 2, archive: ['s3', 'p5'], dim };
    }
    function week(offset) {
      offset = Math.min(0, Math.round(Number(offset) || 0));
      const d = new Date(T0), mon = day0(T0) - ((d.getDay() + 6) % 7) * DAY + offset * 7 * DAY, sun = mon + 6 * DAY;
      const at = (i, h, m) => mon + i * DAY + h * HOUR + m * MIN;
      const wl = x => DAYS[new Date(x).getDay()] + ' ' + hm(x);
      if (sc === 'empty') return { range: { start: ymd(mon), end: ymd(sun), label: md(mon) + '~' + md(sun) }, done: [], progress: [], next: [], missing: [], lastPlan: [],
        heat: { days: ['월', '화', '수', '목', '금', '토', '일'], rows: [] }, copyText: '[한 일]\n\n[진행 중]\n\n[다음]\n' };
      const done = offset === 0 ? [
        { text: '환불 정책 표 정리', kind: 'task', docId: 'f3', line: 3, whenLabel: wl(at(0, 15, 10)), project: '결제', actorLabel: '내가 수정', source: 'rules' },
        { text: 'PAY-141 · 결제 상태 전이 검토', kind: 'issue', docId: 'f2', line: null, whenLabel: wl(at(1, 11, 42)), project: 'PAY', actorLabel: null, source: 'rules' },
        { text: 'TN-004 검색 색인 메모 작성', kind: 'doc', docId: 's2', line: null, whenLabel: wl(at(1, 17, 5)), project: '검색', actorLabel: sessionsOn() ? 'Claude가 작성' : '내가 수정', source: sessionsOn() ? 'claude' : 'rules' },
        { text: '정산 대시보드 숫자 정의 확인', kind: 'task', docId: 'f4', line: 3, whenLabel: wl(at(2, 10, 20)), project: '결제', actorLabel: '내가 수정', source: 'rules' },
      ] : [
        { text: '결제 실패 재시도 정책 초안', kind: 'doc', docId: 'f2', line: null, whenLabel: wl(at(3, 14, 0)), project: '결제', actorLabel: '내가 수정', source: 'rules' },
        { text: '고객 인터뷰 정리', kind: 'task', docId: 'p1', line: 2, whenLabel: wl(at(4, 16, 30)), project: '제품', actorLabel: '내가 수정', source: 'rules' },
      ];
      const progress = [
        { threadId: 't:t1', title: '결제 · 정산 흐름', doneThisWeek: 2, open: 3, lastLabel: label(yAt(18, 40), T0), chips: [{ text: '할 일 3', kind: 'task', source: 'rules' }] },
        { threadId: 't:t2', title: '검색 · 인덱스 설계', doneThisWeek: 1, open: 2, lastLabel: label(day0(T0) - 2 * DAY + 11 * HOUR, T0), chips: [{ text: '기한 D-5', kind: 'due', source: 'rules' }] },
        { threadId: 't:t4', title: '고객 이탈 가설', doneThisWeek: 0, open: 1, lastLabel: label(T0 - 3 * DAY, T0), chips: [{ text: '3일 전 내가 수정', kind: 'activity', source: 'rules' }] },
      ];
      const next = [
        { text: '환불 안내 문구 확정', docId: 'f3', line: 5, due: ymd(day0(T0)), dueLabel: '기한 오늘', project: '결제' },
        { text: 'PAY-147 중복 요청 방지 체크', docId: 'f5', line: null, due: ymd(day0(T0) + DAY), dueLabel: '기한 내일', project: 'PAY' },
        { text: '동의어 사전 갱신', docId: 's2', line: 4, due: ymd(day0(T0) + 5 * DAY), dueLabel: '기한 D-5', project: '검색' },
        { text: '정산 대시보드 카드 순서 확정', docId: 'f4', line: 2, due: null, dueLabel: null, project: '결제' },
        { text: '이탈 가설 인터뷰 질문 만들기', docId: 'p4', line: 3, due: null, dueLabel: null, project: '제품' },
      ];
      const missing = [{ docId: 'f1', title: t('f1'), lines: 42, whenLabel: wl(at(1, 18, 40)) }, { docId: 's1', title: t('s1'), lines: 35, whenLabel: wl(at(0, 9, 30)) }];
      const lastPlan = [{ text: '다음 주: 정산 대시보드 초안 공유', docId: 'p3' }, { text: '다음 주: 검색 순위 실험 결과 정리', docId: 's5' }];
      const heat = { days: ['월', '화', '수', '목', '금', '토', '일'], rows: [
        { threadId: 't:t1', title: '결제 · 정산 흐름', counts: [3, 6, 2, 1, 0, 0, 0] }, { threadId: 't:t2', title: '검색 · 인덱스 설계', counts: [1, 2, 4, 0, 0, 0, 0] },
        { threadId: 't:t4', title: '고객 이탈 가설', counts: [0, 0, 1, 2, 0, 0, 0] }, { threadId: 't:t5', title: '제품 탐색 경험', counts: [0, 1, 0, 0, 0, 0, 0] }] };
      const line = x => '- ' + x;
      const copyText = '[한 일]\n' + done.map(x => line(x.text)).join('\n') + '\n\n[진행 중]\n' + progress.map(x => line(x.title + ' (할 일 ' + x.open + ')')).join('\n') +
        '\n\n[다음]\n' + next.map(x => line(x.text + (x.dueLabel ? ' · ' + x.dueLabel : ''))).join('\n') + '\n';
      return { range: { start: ymd(mon), end: ymd(sun), label: md(mon) + '~' + md(sun) }, done, progress, next, missing, lastPlan, heat, copyText };
    }
    // 정리함 카드 (§6.5). 처음 실행(empty)은 규칙표 카드 1장뿐이다.
    const created = label(day0(T0) + 9 * HOUR + 12 * MIN, T0);
    const RULES = [
      { kind: 'place', pattern: 'ADR-\\d+_*.md', target: '2-Areas/{프로젝트명}/의사결정/', note: '볼트 CLAUDE.md · ADR 위치' },
      { kind: 'place', pattern: 'TN-\\d+_*.md', target: '2-Areas/{프로젝트명}/기술노트/', note: '볼트 CLAUDE.md · TN 위치' },
      { kind: 'frozen', pattern: '1-Projects/정산-설계/', target: '', note: '동결, 참조용' },
      { kind: 'exclude', pattern: '_Templates/', target: '', note: '기본 규칙' },
      { kind: 'landing', pattern: '_workspace/', target: '', note: '기본 규칙' },
    ];
    const mv = (id, docId, from, to, conf, origin, reasons, impact, extra) => Object.assign({ id, kind: 'move', origin,
      originLabel: origin === 'claude' ? 'Claude 제안' : origin === 'codex' ? 'Codex 제안' : '규칙', title: t(docId) + '.md', docId, from, to, alternatives: [],
      confidence: conf, reasons, impact: Object.assign({ links: 0, files: 0, canvas: 0, conflict: null, sync: true }, impact || {}), items: [], rules: [], violations: [], createdLabel: created }, extra || {});
    const cards = [{ id: 's:rules01', kind: 'rules', origin: 'rules', originLabel: '규칙', title: '폴더 규칙표 12개를 확인해 주세요', docId: null, from: null, to: null, alternatives: [],
      confidence: '확정', reasons: ['볼트 CLAUDE.md에서 읽었어요', '승인하기 전에는 이동 제안을 만들지 않아요'], impact: { links: 0, files: 0, canvas: 0, conflict: null, sync: false },
      items: [], rules: RULES, violations: [], createdLabel: created }];
    if (sc !== 'empty') cards.push(
      mv('s:mv0001', 'f4', '_workspace/정산 대시보드 초안.md', '2-Areas/결제/설계/', '확정', 'claude', ['볼트 CLAUDE.md: 설계/ = 화면·기능 설계', '같은 프로젝트 문서 6개와 링크로 이어져요'], { links: 2, files: 1 }),
      mv('s:mv0002', 'f5', '_Inbox/중복 요청 방지 체크.md', '2-Areas/결제/운영/', '추천', 'rules', ['볼트 CLAUDE.md: 운영/ = 쿼리·가이드', '같은 폴더 문서 5개와 주제가 비슷해요'], { links: 1, files: 1, canvas: 1 }),
      { id: 'b:place-tn|3-Resources/검색/', kind: 'bundle', origin: 'rules', originLabel: '규칙', title: '검색 메모 2개', docId: null, from: '_workspace/', to: '3-Resources/검색/', alternatives: [],
        confidence: '추천', reasons: ['같은 규칙 · 같은 목적지', '링크를 고칠 곳이 없어요'], impact: { links: 0, files: 0, canvas: 0, conflict: null, sync: true },
        items: [mv('s:mv0003', 's2', '_workspace/검색어 동의어 노트.md', '3-Resources/검색/', '추천', 'rules', ['TN 규칙']), mv('s:mv0004', 's5', '_workspace/검색 결과 순위 실험.md', '3-Resources/검색/', '추천', 'rules', ['TN 규칙'])],
        rules: [], violations: [], createdLabel: created },
      mv('s:mv0005', 'p1', '고객 인터뷰 발췌.md', '2-Areas/제품/인터뷰/', '후보', 'rules', ['같은 폴더 문서 3개와 주제가 비슷해요', '링크 이웃이 제품 폴더에 많아요'], { links: 0 }, { alternatives: ['2-Areas/제품/리서치/', '3-Resources/고객/'] }),
      mv('s:mv0006', 'i3', '_workspace/단축키 런처 스케치.md', '2-Areas/제품/설계/', '추천', 'codex', ['Codex가 설계 문서로 분류했어요'], { links: 0, conflict: '같은 이름 파일이 있어요' }),
      { id: 's:pol001', kind: 'policy', origin: 'rules', originLabel: '규칙', title: '볼트 지침과 다른 곳 2개', docId: null, from: null, to: null, alternatives: [], confidence: '확정',
        reasons: ['월요일 점검 결과예요', '사서는 파일을 고치지 않아요'], impact: { links: 0, files: 0, canvas: 0, conflict: null, sync: false }, items: [], rules: [],
        violations: [{ text: 'ADR-003이 프로젝트_요약.md에 없어요', docId: 'f1' }, { text: 'TN-002 번호가 두 번 쓰였어요', docId: 's2' }], createdLabel: created });
    const used = { today: 3 };
    function pendingCount() { return cards.length + tidy.cards().length; }
    function log(kind, text, extra) {
      st.log.unshift(Object.assign({ id: 'l' + (++st.logNo), ts: new Date().toISOString(), kind, text, origin: 'rules', batchId: null, undoable: false }, extra || {}));
      emit('log');
    }
    [['policy', '규칙표를 만들었어요 · 12개', 26 * HOUR], ['session', '세션 기록을 읽었어요 · Claude 2 · Codex 1', 25 * HOUR],
      ['apply', '옮겼어요: 결제 회의록 → 2-Areas/결제/회의/ · 링크 1개 고침', 24 * HOUR, { batchId: 'b-seed', undoable: true }],
      ['check', '새 문서를 확인했어요: 정산 대시보드 초안', 5 * HOUR], ['inPlace', '제자리예요: TN-004 검색 색인', 5 * HOUR - 3 * MIN],
      ['propose', '제안했어요: 정산 대시보드 초안 → 2-Areas/결제/설계/', 4 * HOUR, { origin: 'claude' }], ['summary', '한 줄 요약 3개를 채웠어요 (규칙)', 2 * HOUR]]
      .forEach(([k, txt, ago, ex]) => st.log.push(Object.assign({ id: 'l' + (++st.logNo), ts: new Date(T0 - ago).toISOString(), kind: k, text: txt, origin: 'rules', batchId: null, undoable: false }, ex || {})));
    st.log.sort((a, b) => b.ts.localeCompare(a.ts));
    const ORIGIN = { rules: '규칙', apple: '기기 AI', claude: 'Claude', codex: 'Codex' };
    function pending() {
      const show = cards.slice(0, 5);
      const n = sc === 'empty' ? 0 : 5;
      return { header: { aiDid: '어제 이후 사서가 한 일: 새 문서 ' + n + ' 확인 · 제자리 ' + (sc === 'empty' ? 0 : 3) + ' · 제안 ' + Math.max(0, cards.length - 1) + '(규칙 ' + cards.filter(c => c.origin === 'rules' && c.kind !== 'rules').length + ' · Claude ' + cards.filter(c => c.origin === 'claude').length + ') · 적용 ' + st.batches.length,
          checked: n, inPlace: sc === 'empty' ? 0 : 3, proposed: Math.max(0, cards.length - 1), applied: st.batches.length },
        cards: show.concat(tidy.cards()), more: Math.max(0, cards.length - show.length),
        limits: { perApply: 5, perDay: 10, usedToday: used.today, firstWeeks: true }, policy: { approved: st.approved, stale: false },
        stopped: st.stopped, lastBatchLabel: sc === 'empty' ? null : '오늘 ' + (new Date(T0).getHours() >= 12 ? '12:00' : '09:00') };
    }
    function applyMoves(list) {
      if (st.stopped) return { ok: false, error: '사서가 멈춰 있어서 옮기지 않았어요' };
      const skipped = [], moved = [];
      list.forEach(c => { if (c.impact && c.impact.conflict) skipped.push({ title: c.title, reason: c.impact.conflict }); else moved.push(c); });
      if (used.today + moved.length > 10) return { ok: false, error: '오늘 상한(10건)을 넘어요' };
      const batchId = 'b-' + (++st.batchNo);
      used.today += moved.length;
      const rewrote = moved.reduce((n, c) => n + ((c.impact && c.impact.links) || 0), 0);
      if (moved.length) {
        st.batches.push({ batchId, cards: moved });
        log('apply', '옮겼어요: ' + moved.map(c => c.title.replace(/\.md$/, '') + ' → ' + c.to).join(', ') + (rewrote ? ' · 링크 ' + rewrote + '개 고침' : ''), { batchId, undoable: true });
      }
      return { ok: true, applied: { batchId: moved.length ? batchId : null, moved: moved.length, rewrote, skipped }, undoable: moved.length > 0 };
    }
    function decide(p) {
      if (String(p.id || '').indexOf('t:') === 0) return tidy.methods.tidyDecide({ id: p.id, action: p.action === 'edit' ? 'to' : p.action, to: p.to });   // v0.9 정리함의 tidy 카드
      const i = cards.findIndex(c => c.id === p.id);
      if (i < 0) return { ok: false, error: '이미 처리한 카드예요' };
      const c = cards[i], a = p.action;
      let r = { ok: true, applied: null, undoable: false };
      if (c.kind === 'jira') {   // v0.8: Jira 카드는 거절만 여기서 한다. 반영은 jiraApply (§6.1)
        if (a !== 'reject') return { ok: false, error: 'Jira 변경은 jiraApply로 반영해요' };
        cards.splice(i, 1); ai.cardState(c.id, 'rejected');
        log('reject', '거절했어요: ' + c.key + ' ' + (c.op === 'comment' ? '댓글' : c.op === 'transition' ? '상태 전환' : '새 티켓'));
        emit('pending');
        return r;
      }
      if (c.kind === 'rules') {
        if (a === 'approve') { st.approved = true; log('policy', '규칙표를 승인했어요'); emit('policy'); }
        else if (a !== 'later' && a !== 'reject') return { ok: false, error: '규칙표 카드는 승인하거나 나중에 볼 수 있어요' };
      } else if (c.kind === 'policy') {
        if (a !== 'dismiss' && a !== 'reject' && a !== 'later') return { ok: false, error: '정책 카드는 닫기만 할 수 있어요' };
      } else if (a === 'approve' || a === 'edit') {
        const target = a === 'edit' ? String(p.to || '') : c.to;
        if (!target) return { ok: false, error: '목적지를 골라 주세요' };
        const list = c.kind === 'bundle' ? c.items : [Object.assign({}, c, { to: target })];
        r = applyMoves(list);
        if (!r.ok) return r;
      } else if (a === 'reject') log('reject', '거절했어요: ' + c.title);
      else if (a !== 'later') return { ok: false, error: '알 수 없는 동작이에요' };
      if (a !== 'later') ai.cardState(c.id, a === 'reject' ? 'rejected' : 'applied');   // 시키기 패널이 실행 카드의 결과를 보도록
      cards.splice(i, 1);
      if (a === 'later') cards.push(c);
      emit('pending'); emit('home');
      return r;
    }
    function undo(p) {
      if (p && tidy.isTidyBatch(p.batchId)) return tidy.undo(p);
      const k = p && p.batchId ? st.batches.findIndex(b => b.batchId === p.batchId) : st.batches.length - 1;
      if (p && p.batchId === 'b-seed') { log('undo', '되돌렸어요: 결제 회의록'); st.log.forEach(e => { if (e.batchId === 'b-seed') e.undoable = false; }); return { ok: true, restored: 1, conflicts: [] }; }
      if (k < 0) return { ok: false, error: '되돌릴 적용이 없어요' };
      const b = st.batches.splice(k, 1)[0];
      b.cards.forEach(c => cards.unshift(c));
      used.today = Math.max(0, used.today - b.cards.length);
      st.log.forEach(e => { if (e.batchId === b.batchId) e.undoable = false; });
      log('undo', '되돌렸어요: ' + b.cards.map(c => c.title.replace(/\.md$/, '')).join(', '));
      emit('pending'); emit('home');
      return { ok: true, restored: b.cards.length, conflicts: [] };
    }
    function aiLog(p) {
      const lim = Math.max(1, Math.min(500, Number(p && p.limit) || 100));
      return { entries: st.log.slice(0, lim).map(e => Object.assign({}, e, { tsLabel: hm(Date.parse(e.ts)),
        day: (() => { const d = Math.round((day0(T0) - day0(Date.parse(e.ts))) / DAY); return d === 0 ? '오늘' : d === 1 ? '어제' : md(Date.parse(e.ts)); })(),
        originLabel: ORIGIN[e.origin] || e.origin })), engine: engine() };
    }
    const engine = () => ({ apple: 'off', reason: 'Apple Intelligence가 꺼져 있어요', label: '규칙', pending: 0 });
    function settings() {
      const on = sessionsOn(), found = sc !== 'empty';
      return { sessions: { enabled: st.sessions, requestText: st.requestText,
          claude: { dir: '~/.claude/projects', found, files: on ? 42 : 0, sessions: on ? 18 : 0 }, codex: { dir: '~/.codex/sessions', found, files: on ? 9 : 0, sessions: on ? 6 : 0 },
          lastScan: on ? new Date(T0 - 4 * MIN).toISOString() : null, writesMatched: on ? 23 : 0, error: null,
          fields: ['세션 제목', '작업 폴더', '브랜치', 'AI가 쓴 파일 경로', '시각', '내 요청 첫 줄(80자)'] },
        engine: engine(), stopped: st.stopped, mcpRemoteBodies: st.remoteBodies, policy: { approved: st.approved, stale: false, ruleCount: 12 }, tidy: tidy.rules(), workmapScope: tidy.scope() };
    }
    function setSetting(p) {
      const k = p.key, v = String(p.value);
      if (k === 'sessions.enabled') { st.sessions = v === '1'; if (st.sessions) st.cleared = false; log('session', st.sessions ? '세션 기록을 켰어요' : '세션 기록을 껐어요'); }
      else if (k === 'sessions.requestText') st.requestText = v === '1';
      else if (k === 'sessions.clear') { st.cleared = true; st.sessions = false; log('session', '세션 기록을 지웠어요'); }
      else if (k === 'brain.stopped') { st.stopped = v === '1'; log('stop', st.stopped ? '사서를 멈췄어요' : '다시 시작했어요'); }
      else if (k === 'mcp.remoteBodies') st.remoteBodies = v === '1';
      else { const tr = tidy.setSetting(k, String(p.value == null ? '' : p.value)); return tr || { ok: false, error: '알 수 없는 설정이에요' }; }
      emit('settings'); emit('home'); if (k === 'brain.stopped') emit('pending');
      return { ok: true };
    }
    function policy() {
      return { approved: st.approved, stale: false, sources: [{ path: 'CLAUDE.md', mtimeLabel: '10/20' }, { path: '2-Areas/결제/CLAUDE.md', mtimeLabel: '10/18' }],
        rules: RULES.map(r => Object.assign({ source: 'CLAUDE.md' }, r)), counts: { place: 3, frozen: 2, exclude: 5, landing: 2, duty: 0 },
        violations: [{ text: 'ADR-003이 프로젝트_요약.md에 없어요', docId: 'f1' }] };
    }
    function instruction(p) {
      const c = p.context;
      if (c === 'thread') {
        const x = THREADS.find(th => 't:' + th.tid === p.id || 'thread:t:' + th.tid === p.id);
        return { ok: true, text: 'Synapse MCP의 get_work_context로 \'' + (x ? st.names.get('thread:t:' + x.tid) || x.title : '이 흐름') + '\' 작업 맥락을 보고, 내가 하던 일과 다음에 할 일을 정리해 줘.' };
      }
      return INSTR[c] ? { ok: true, text: INSTR[c] } : { ok: false, error: '알 수 없는 지시문이에요' };
    }
    // v0.8: Claude 연결 흉내 (aiStatus·aiDigest·aiTask·jiraApply …). 티켓 자료는 사서 시나리오 'tickets'·'jira' 또는 window.__MOCK_TICKETS=true 일 때만.
    const addCard = c => { cards.splice(cards.length && cards[0].kind === 'rules' ? 1 : 0, 0, c); };
    const removeCard = id => { const i = cards.findIndex(c => c.id === id); if (i >= 0) cards.splice(i, 1); };
    hasTickets = sc === 'tickets' || sc === 'jira' || window.__MOCK_TICKETS === true;
    const tidy = createTidy({ T0, sc, t, emit, log, stopped: () => st.stopped });   // v0.9 작업 지도·정리 비서
    ai = createAI({ T0, t, ai: opts.ai, hasTickets, mv, log, emitBrain: emit, addCard, removeCard, tidy });
    if (sc === 'jira') ai.seedJiraCards().forEach(addCard);
    const METHODS = {
      home, why: p => why(p.id), feedback, week: p => week(p.offset), map, pending, decide,
      decideBundle: p => { const c = cards.find(x => x.id === p.id); return c && c.kind === 'bundle' ? decide({ id: p.id, action: 'approve' }) : { ok: false, error: '묶음 카드가 아니에요' }; },
      undo, aiLog, brainSettings: settings, setBrainSetting: setSetting, policy,
      approvePolicy: () => { st.approved = true; const i = cards.findIndex(c => c.kind === 'rules'); if (i >= 0) cards.splice(i, 1); log('policy', '규칙표를 승인했어요'); emit('policy'); emit('pending'); return { ok: true }; },
      folders: () => ({ folders: ['1-Projects/결제-설계/', '1-Projects/정산-설계/', '2-Areas/결제/', '2-Areas/결제/설계/', '2-Areas/결제/운영/', '2-Areas/결제/의사결정/',
        '2-Areas/결제/기술노트/', '2-Areas/제품/', '2-Areas/제품/인터뷰/', '2-Areas/제품/리서치/', '2-Areas/제품/설계/', '3-Resources/검색/', '3-Resources/고객/', '3-Resources/디자인-자료/'] }),
      claudeInstruction: instruction, track: () => ({ ok: true }), runBatch: () => { log('check', '지금 다시 봤어요 · 새 제안 없음'); return { ok: true, created: 0 }; },
    };
    Object.assign(METHODS, ai.methods, tidy.methods);
    return {
      methods: Object.keys(METHODS),
      call(method, params) {
        return new Promise(res => setTimeout(res, 20)).then(() => {
          if (sc === 'nobrain') return { ok: false, error: '사서를 열지 못했어요' };
          const fn = METHODS[method];
          if (!fn) return { ok: false, error: '알 수 없는 method: ' + method };
          return fn(params || {});   // 값 또는 Promise(aiTest·jiraApply)
        }).then(r => JSON.parse(JSON.stringify(r)));
      },
    };
  }
  window.SynapseDemoBrain = Object.freeze({ create });
})();
