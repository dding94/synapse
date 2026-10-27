# Atlassian MCP 모의 서버

Synapse MCP 클라이언트(`Library/Remote/MCPClient.swift`·`MCPAuth.swift`·`AtlassianMCP.swift`)를 실제 Atlassian 없이 시험하는 python3 표준 라이브러리 서버. 가짜 한국어 자료만 들어 있고 127.0.0.1에만 바인딩한다.

```
python3 dev/mcp-mock/server.py 8790      # MCP 주소 http://127.0.0.1:8790/mcp
```

- OAuth: 401 `WWW-Authenticate: Bearer resource_metadata=…` → `/.well-known/oauth-protected-resource/mcp` → `/.well-known/oauth-authorization-server`(설정 `oidc_only`면 404, `openid-configuration`만) → `/register` → `/authorize`(바로 302로 code·state 돌려줌) → `/token`(PKCE S256 확인, 갱신 토큰 회전).
- MCP: `initialize`가 `Mcp-Session-Id`를 주고, 이후 세션·`MCP-Protocol-Version` 헤더가 없으면 400/404. 도구 6개, 검색은 2건씩 2쪽, 첫 Jira 검색은 HTTP 429(Retry-After 1).
- 자료: `fixtures/pages.json`(PAY: 정산 프로세스 ← 환불 예외 처리·월말 정산 체크리스트, 결제 장애 대응), `fixtures/issues.json`(PAY-150 → PAY-142 연결·부모 PAY-100, 댓글).
- 시험 제어(인증 없음): `POST /__config` `{sse, oidc_only, deny, fail_refresh, malformed, no_confluence, short_expiry, throttle, expire_all, drop_sessions, touch:{pages,issues}}`, `GET /__stats`, `POST /__reset`.

## v0.5 Jira 필드 시험
- `fixtures/issues.json`에 `priority`·`duedate`·`assignee`(accountId)·`status.statusCategory`가 들어 있다. `atlassianUserInfo`의 `account_id`는 `712020:mock-cheolsu`(PAY-150·PAY-120이 내 이슈).
- `meta-check/main.swift`: 연결기를 모의 서버에 실제로 붙여 `DocRecord.meta`(status·statusCategory·priority·duedate·assignee·mine·issuetype·updated)와 "atlassianUserInfo는 동기화당 한 번"을 확인한다.
  ```
  python3 dev/mcp-mock/server.py 8790 &
  swiftc -swift-version 5 -target arm64-apple-macos14.0 dev/mcp-mock/meta-check/main.swift $(find Library -name '*.swift' | LC_ALL=C sort) \
    -o /tmp/meta-check -framework AppKit -framework WebKit -framework Carbon -framework PDFKit -framework NaturalLanguage \
    -framework Security -framework CoreServices -Xlinker -weak_framework -Xlinker FoundationModels -lsqlite3 && MOCK_PORT=8790 /tmp/meta-check
  ```

## v0.8 Jira 쓰기 시험 (JiraWriter)
- 도구 6개를 더 흉내 낸다: `getJiraIssue`·`getTransitionsForJiraIssue`·`transitionJiraIssue`(`transition.id`는 문자열)·`addCommentToJiraIssue`(`contentFormat: "markdown"`, `commentId` 없음)·`getJiraProjectIssueTypesMetadata`(작업·버그·에픽·하위 작업)·`createJiraIssue`. 바꾼 내용은 검색(`searchJiraIssuesUsingJql`) 결과에도 바로 나온다.
- 상태 흐름: `11` 해야 할 일 · `21` 진행 시작→진행 중 · `31` Done→완료 · `41` 보류→Blocked (지금 상태로 가는 전환은 목록에서 뺀다).
- `POST /__config`: `write_fail`(`"isError"`·`"403"`·`"401"`·`"500"`·`"drop"` = 쓰지 않고 실패, `"500_after"`·`"drop_after"` = 쓴 뒤 실패(결과를 모르는 실패)), `write_delay`(초, 동시 반영 시험), `meta_fail`·`transitions_fail`·`issue_fail`(읽기 도구 오류), `set_status: {"PAY-150": "완료"}`(Jira 밖에서 상태가 바뀐 상황).
- `POST /__token`: 브라우저 로그인 없이 시험용 자격 증명(Synapse `MCPCredential` JSON)을 발급한다 — `synapse-cli brain jira-apply`에는 `SYNAPSE_CLI_MCP_CREDENTIAL`로 넘긴다(메모리 비밀 저장소일 때만).
- `GET /__jira`: 이슈 상태·유형·댓글, 쓰기 기록(`writes`), 도구 호출 수.
