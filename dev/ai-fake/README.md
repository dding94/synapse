# dev/ai-fake — 시험용 가짜 Claude Code (v0.8)

진짜 Claude·네트워크를 부르지 않는 `claude` 대역이에요. Synapse 시험은 이것을 `SYNAPSE_CLAUDE_BIN`으로 써요(docs/V08.md §10).

```bash
export SYNAPSE_CLAUDE_BIN="$PWD/dev/ai-fake/claude"
build/synapse-cli --home <시험 홈> ai digest week --run force --wait
FAKE_CLAUDE_MODE=login build/synapse-cli --home <시험 홈> ai test
FAKE_CLAUDE_MODE=slow FAKE_CLAUDE_DELAY=60 build/synapse-cli --home <시험 홈> ai task "오래 걸리는 일" --wait   # 다른 창에서 ai cancel <runId>
```

- 시험 모드(앱은 `SYNAPSE_TEST_*`, CLI는 기본 홈이 아닐 때)에서는 `SYNAPSE_CLAUDE_BIN`이 없으면 Claude가 없는 것으로 봐요.
- Synapse는 claude를 새 환경(HOME·PATH 등만)으로 띄우지만, 시험 모드에서는 `FAKE_CLAUDE_*` 변수를 그대로 넘겨요.
- `--version` → `2.1.310 (Claude Code)`
- `-p --output-format json --json-schema S` → stdin을 읽고 스키마 속성으로 종류를 알아내 `structured_output`을 만들어요
  (sections→week, focus→tickets, today→home, summary+points→doc, v0.9 summary+items+questions→tidy). 참조는 stdin 안의 `J1`·`T3` 같은 토큰을 써서 정규화를 통과해요.
  tidy는 입력의 `P#`(자리)·`R#`(원자료)·`D#`(목적지)로 티켓 폴더 옮기기·운영 자료 옮기기(확인 필요)·원자료 제외·비밀 파일 알림을 만들어요.
  스키마가 없으면 지시에 "OK"가 있을 때 `OK`라고 답해요(aiTest).
- `--output-format stream-json` → init → assistant 글 → tool_use(`mcp__synapse__list_pending`) → tool_result → assistant 글 → result.
  `--mcp-config`의 synapse 서버를 실제로 띄워 도구를 불러요(그래서 `SYNAPSE_RUN_ID`가 붙은 제안도 만들 수 있어요).
  `--allowedTools` 밖의 도구는 `permission_denied`와 `is_error` 결과로 거절해요.

| 변수 | 뜻 |
|---|---|
| `FAKE_CLAUDE_MODE` | `login` · `limit`(풀리는 시각 포함) · `slow` · `badjson`(JSON 아님) · `badshape`(스키마와 다른 모양) · `crash`(stderr + 종료 3) · `network` |
| `FAKE_CLAUDE_DELAY` | 답하기 전에 쉬는 초(소수 가능). `slow`는 이 값(없으면 600초)만큼 쉬어요 |
| `FAKE_CLAUDE_LOG` | 받은 인자·cwd·환경 변수 이름을 JSON 한 줄씩 덧붙일 파일(금지 플래그 확인용) |
| `FAKE_CLAUDE_TOOLS` | stream 모드에서 부를 도구 JSON. 예: `[{"name":"propose_changes","input":{"items":[…]}}]` |
| `FAKE_CLAUDE_IGNORE_TERM` | `1`이면 SIGTERM을 무시해요(취소의 3초 뒤 SIGKILL 시험) |
| `FAKE_CLAUDE_MCP` | `0`이면 MCP 서버를 띄우지 않고 지어낸 결과를 돌려줘요 |

시간 제한 시험은 `SYNAPSE_TEST_AI_TIMEOUT=<초>`(시험 모드에서만, 낮추기만 해요)와 `FAKE_CLAUDE_MODE=slow`를 함께 써요.
