# Synapse

단축키(`⌃⌥Space`)로 부르는 macOS 개인 검색·작업 관제 앱이에요. 내 폴더의 문서, 옵시디언 볼트, Confluence·Jira를 원래 자리에서 읽어 한곳에서 찾고, 열면 "지금 하던 일·다음 할 일·정리할 것"을 먼저 보여 줘요. 화면은 한국어예요.

- **검색**: 조사가 붙어도 찾고(`회의록을` → 회의록), 초성(`ㅎㅇㄹ`)과 동의어로도 찾아요. md·txt·PDF·워드·RTF·ODT·HTML·한글(hwpx)을 읽어요.
- **홈**: 급한 것(기한·내 Jira), 지금 하던 일(멈춘 곳 바로 열기), 이어서 할 일을 보여 줘요.
- **작업 지도**: 티켓을 지금·다음·기다림으로 나누고, PARA 폴더(1-Projects·2-Areas·3-Resources·4-Archive)를 건강 상태로 보여 줘요.
- **정리 비서**: 데스크톱과 볼트를 살펴 옮기기·합치기·보관·색인 제외를 제안해요. 확실한 것만 자동으로 하고, 나머지는 승인을 받아요. 모든 정리는 되돌릴 수 있어요.
- **Claude 연결(선택)**: 이 Mac의 Claude Code로 이번 주 정리, 티켓 브리핑, 주간보고 초안, 정리 계획을 만들어요.
- **MCP 서버**: Claude Code·Codex가 Synapse 색인을 검색 도구로 쓸 수 있어요.

색인과 기록은 이 Mac 안에만 저장해요(`~/Library/Application Support/Synapse/`).

## 설치

요구 사항:
- macOS 14(Sonoma) 이상, Apple Silicon·Intel 모두 됨
- Xcode Command Line Tools (`xcode-select --install`)
- 선택: Claude Code (AI 정리), Atlassian 계정 (Confluence·Jira)

설치하면 이 Mac에서 소스를 직접 빌드해요(5~10분). 그래서 "확인되지 않은 개발자" 경고 없이 열려요.

**한 줄 설치 (추천)** — `~/Applications/Synapse.app`과 `~/.local/bin/synapse-cli`가 생겨요.

```bash
curl -fsSL https://raw.githubusercontent.com/dding94/synapse/main/install.sh | bash
```

**Homebrew** — tap을 한 번 등록하면 그다음부터는 이름만으로 설치해요.

```bash
brew tap dding94/tap
brew install synapse
```

한 줄로 하려면 `brew install dding94/tap/synapse`도 돼요(tap 등록까지 함께 해요).

설치가 끝나면 앱을 응용 프로그램 폴더에 연결해요.

```bash
ln -sfn "$(brew --prefix synapse)/Synapse.app" ~/Applications/Synapse.app
```

**소스나 압축 파일로**: 압축을 풀었거나 `git clone`한 폴더 안에서 실행해요.

```bash
./install.sh
```

- 설치 위치는 `SYNAPSE_INSTALL_DIR`(기본 `~/Applications`)와 `SYNAPSE_BIN_DIR`(기본 `~/.local/bin`)로 바꿀 수 있어요.
- 업데이트는 같은 명령을 다시 실행하거나 `brew upgrade synapse`를 해요.
- Synapse가 켜져 있었다면 설치 뒤 한 번 다시 열어 주세요.

## 처음 쓰기

1. `open ~/Applications/Synapse.app`으로 열고, 다음부터는 `⌃⌥Space`로 불러요(사용 중이면 `⌃⌥⌘Space`). 메뉴 막대 아이콘도 생겨요.
2. 헤더의 **자료**에서 출처를 더해요.
   - **폴더**: 데스크톱·문서 폴더 등. 처음 읽을 때 macOS가 폴더 접근 허용을 물어요.
   - **옵시디언 볼트**: `.obsidian`이 있는 폴더는 볼트로 알아봐요(`[[링크]]`·별칭·태그·프런트매터).
   - **Atlassian (MCP 로그인)**: 브라우저로 한 번 로그인하면 내가 쓰거나 참여하거나 지켜보는 Confluence 페이지와 Jira 이슈(최근 1년)를 가져와요. 토큰은 키체인에만 저장해요.
3. 출처가 없을 때는 "예시 자료로 둘러보기"로 가상의 팀 자료를 볼 수 있어요.

- 한 출처 안에 다른 출처가 겹치면 안쪽 출처만 그 경로를 색인해요(중복 없음).
- 출처마다 `형식·폴더`에서 색인할 확장자와 뺄 하위 폴더를 고를 수 있어요.

## 화면

| 화면 | 키 | 하는 일 |
|---|---|---|
| 홈 | ⌘1 | 급한 것(기한·내 Jira), 지금 하던 일, 이어서, 잠듦. 맨 위에 티켓 한 줄과 정리 한 줄 |
| 작업 지도 | ⌘2 | 티켓 지금·다음·기다림 + 영역·프로젝트·정리 안 됨·자료·보관 폴더의 건강 상태. 오른쪽 상세에서 정리 제안 승인, `g` = 연결 보기, `p` = 정리 계획, `⌥⌘2` = 전체 그래프 |
| 정리함 | ⌘3 | 자리 제안·정리 비서 카드를 `y` 승인 · `n` 거절 · `e` 목적지 · `s` 나중에. `⌥⌘Z` 되돌리기 |
| 이번 주 | ⌘4 | 이번 주 한 일·상태 변경·다음 주 계획. Claude가 연결돼 있으면 영역별 정리와 주간보고 초안(`⌘⇧C` 복사) |
| 티켓 | ⌘5 | 열린 Jira 티켓을 프로젝트별로(막힘·진행 중·할 일, 내 담당만, 7일 넘게 그대로) |
| Claude 시키기 | ⌘J | 빠른 작업과 자유 지시. 파일·Jira 변경은 제안만 하고 사람이 승인해요 |
| AI 기록 | ⌘Y | 정리 비서·Claude가 한 일, 되돌리기, 비상 정지 |

## 정리 비서와 안전 규칙

방법은 PARA에 두 가지를 더한 거예요. **티켓마다 폴더 하나**(`_workspace/<티켓 키>`)와 **일주일에 한 번 정리 리뷰**(기본 금요일)예요.

- **정리 계획**: 규칙(10분마다)과 Claude(작업 지도를 열 때, 6시간 간격)가 제안을 만들어요. 묶음은 데스크톱 정리·티켓 폴더·보관·색인·확인 필요로 나뉘고, 카드마다 이유·근거·확실성·링크 영향이 붙어요.
- **자동 정리**: 기본 규칙 두 개만 자동이에요.
  - 이름에 티켓 키가 있는 파일을 이미 있는 그 티켓 폴더로 옮기기
  - 확실한 원자료 폴더(raw·data·results 등)를 색인에서 빼기
  - 24시간 넘게 그대로이고 링크를 고칠 일이 없을 때만, 하루 20건까지 해요.
  - 같은 종류를 3번 승인하면 앞으로 자동으로 할지 물어요. Claude가 만든 제안은 그래도 '확실'일 때만 자동으로 해요.
- **지우지 않아요**: 휴지통으로 보내기는 언제나 승인을 받아요. Synapse 휴지통에 30일 둔 뒤 macOS 휴지통으로 옮겨요.
- **비밀 파일**: `.env`·키·인증서 같은 비밀 파일은 읽지도 옮기지도 않고 알리기만 해요. 숨김 폴더 안까지 이름으로 확인하고, 다 확인하지 못한 폴더는 옮기지 않아요.
- **그 밖의 보호**: 심볼릭 링크를 지나는 경로는 건드리지 않아요. 코드 저장소(git)는 볼트로 옮기지 않고 코드 폴더(기본 `~/IdeaProjects`)로만 옮겨요.
- **되돌리기**: 모든 이동은 기록을 먼저 남기고 되돌릴 수 있어요(`⌥⌘Z`). 볼트 안 폴더를 옮기면 경로형 링크를 고치고, 링크가 깨지면 자동으로 되돌려요.
- **비상 정지**: 메뉴 막대 아이콘 우클릭으로 모든 쓰기를 멈춰요.

## Claude 연결 (선택)

이 Mac에 설치된 Claude Code(`claude`)를 Synapse가 화면 없이(headless) 실행해요. API 키는 필요 없고, 사용량은 Claude Code에 로그인한 계정의 요금제에서 나가요.

- **정리**: 이번 주·티켓·홈 브리핑·정리 계획을 만들어요. 화면을 열 때 바뀐 게 있으면 자동으로 다시 만들어요(쉼 간격과 하루 상한이 있어요).
- **시키기(⌘J)**: Claude는 Synapse MCP 도구만 써요(셸·웹·파일 도구 없음). 변경은 모두 제안으로만 올려요.
- **보내는 내용**: 문서 제목, 폴더 이름, 티켓 키·상태 같은 정리 입력이에요. AI 세션 대화 문장과 비밀 파일 이름은 보내지 않아요.
- **설정**(자료와 설정 → Claude): 켜기·자동 정리, 모델, 경로, 주간보고 양식을 바꿔요.
- 로그인 오류가 나면 터미널에서 `claude`를 한 번 실행해 `/login` 해 주세요.

## Claude Code·Codex에서 Synapse 쓰기 (MCP)

앱 안의 `synapse-mcp`가 MCP 서버예요. 앱이 꺼져 있어도 디스크의 색인으로 동작해요.

```bash
claude mcp add --scope user synapse -- ~/Applications/Synapse.app/Contents/MacOS/synapse-mcp
```

Codex(`~/.codex/config.toml`):

```toml
[mcp_servers.synapse]
command = "/Users/<사용자>/Applications/Synapse.app/Contents/MacOS/synapse-mcp"
```

도구:
- 검색: `search_notes`, `get_note`, `related_notes`, `recent_notes`, `list_sources`
- 작업: `get_work_context`, `get_tickets`, `get_vault_policy`, `list_pending`, `suggest_location`
- 제안: `propose_changes`, `propose_jira_changes`. 적용은 Synapse에서 사람이 승인해요.
- `apply_changes`(바로 실행)는 기본으로 꺼져 있어요.

## 조작

| 키 | 동작 |
|---|---|
| `↑` `↓` · `↵` | 결과 이동 · 읽기 |
| `⌘↵` / `⌘O` · `⌥⌘R` | 기본 앱으로 열기 · Finder에서 보기 |
| `⇥` · `⌘[` `⌘]` | 선택 문서로 연결 따라가기 · 뒤로/앞으로 |
| `esc` | 읽기 닫기 → 처음으로 → 창 숨기기 |
| `⌘F` · `⌘\` | 검색창으로 · 오른쪽 미리보기 열고 닫기 |
| `⌘E` · `⌘S` · `⌘N` | 편집 · 저장(md·txt) · 새 노트(`[[` 자동완성) |
| `⌘1`~`⌘5` · `⌥⌘2` | 홈 · 작업 지도 · 정리함 · 이번 주 · 티켓 · 그래프 |
| 작업 지도 | `←` `→` 접기·펼치기 · `⇥` 목록↔상세 · `y` `n` `e` 카드 · `g` 연결 보기 · `p` 정리 계획 |
| `⌘J` · `⌘Y` · `⌘/` | Claude 시키기 · AI 기록 · 왜 여기에? |
| `⌥⌘Z` · `⌘⌫` | 직전 정리 되돌리기 · Synapse 휴지통으로 |
| 우클릭 | 문서 메뉴: 읽기·편집·옮기기·휴지통·경로 복사 |

- 편집: 저장할 때마다 직전 버전을 `~/Library/Application Support/Synapse/backups/`에 남겨요.
- 다른 곳에서 먼저 바뀐 파일은 덮어쓰기 전에 물어요.

## 지우기

```bash
rm -rf ~/Applications/Synapse.app ~/.local/bin/synapse-cli ~/.local/bin/synapse-mcp
rm -rf ~/Library/Application\ Support/Synapse   # 색인·기록까지 지울 때
```

Homebrew로 설치했다면 `brew uninstall synapse`를 실행하고, 위 링크도 지워 주세요.

## 개발

```bash
./build.sh                # 화면 번들 + 앱·CLI·MCP 빌드 → dist/Synapse.app (SYNAPSE_OUTPUTS로 바꿈)
./build.sh --run          # 빌드 후 실행
./build.sh --html         # 화면(Graph.html)만 다시 번들 — 브라우저로 열면 예시 자료로 동작
build/synapse-cli --home /tmp/syn add-folder dev/fixtures/테스트볼트 --obsidian
build/synapse-cli --home /tmp/syn index
build/synapse-cli --home /tmp/syn view search 회의록을
build/synapse-cli --home /tmp/syn brain workmap        # 작업 지도 자료
tools/package.sh          # 배포용 tar.gz 만들기 (공개 점검을 통과해야 만들어져요)
```

- 이 Mac에만 둘 빌드 설정(예: 출력 폴더)은 `build.local.sh`에 적어요(git에 올라가지 않아요).
- 기본 위치가 아닌 `--home`은 시험 모드예요. 키체인 대신 메모리를 쓰고, AI 세션 폴더는 지정할 때만 읽어요.
- 시험 도구:
  - `dev/ai-fake/claude`: 가짜 Claude Code (`SYNAPSE_CLAUDE_BIN`)
  - `dev/atlassian-mock`·`dev/mcp-mock`: 가짜 Atlassian
  - `dev/ui-test/run.sh`: 화면 밖 앱 시나리오 시험
  - `dev/fixtures`: 가상의 볼트와 세션
- 구조:
  - `main.swift`: 창·메뉴 막대·단축키·웹뷰 브리지
  - `Library/`: 색인·추출·원격 연결
  - `Library/Brain/`: 홈·작업 흐름·정리함
  - `Library/Tidy/`: 정리 비서
  - `Library/AI/`: Claude 연결
  - `src/`: 화면(바닐라 JS·CSS → 한 장짜리 `Graph.html`)
  - `tools/cli`·`tools/mcp`: CLI·MCP 서버

## 라이선스

MIT — [LICENSE](LICENSE)
