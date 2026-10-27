# Atlassian 모의 서버

Synapse 연결기(`Library/Remote/Atlassian.swift`)를 실제 Atlassian 없이 시험하는 python3 표준 라이브러리 서버. 가짜 한국어 자료만 들어 있다.

```
python3 dev/atlassian-mock/server.py 8765      # 127.0.0.1:8765
```

- 사이트 주소 `http://127.0.0.1:8765`, 이메일 아무거나, 토큰 `test-token` (다르면 401).
- `/rest/api/3/myself`, `/wiki/rest/api/content/search`(한 쪽 2건, 3쪽, `_links.next`), `/rest/api/3/search/jql`(2건씩 2쪽, `nextPageToken`).
- 첫 Jira 요청은 `429` + `Retry-After: 1` (서버당 한 번). `POST /__reset`으로 되돌림, `GET /__stats`로 요청 수 확인.
- 증분 조건 `lastmodified >= "yyyy-MM-dd HH:mm"` / `updated >= "…"`만 해석한다 (시각은 +09:00로 간주).
- `MOCK_NO_CONFLUENCE=1`이면 Confluence가 404 (Jira만 있는 사이트).
- v0.5: Jira 이슈에 `priority`·`duedate`·`assignee`·`status.statusCategory`가 있고, `/rest/api/3/myself`의 `accountId`는 `mock-1`이다(PAY-142·PAY-120이 내 이슈). `/__stats`의 `counts.myself`로 호출 수를 본다.
- 자료: `fixtures/confluence_pages.json`(PAY 스페이스 6쪽: 정산 프로세스 ← 환불 예외 처리 등), `fixtures/jira_issues.json`(PAY-142, PAY-150(→PAY-142 연결, 부모 PAY-100), PAY-100, PAY-120).
- http는 연결기가 127.0.0.1·localhost에서만 허용한다. 운영은 https만.
- v0.8 Jira 쓰기(JiraWriter REST): `GET /rest/api/3/issue/{key}?fields=status`, `GET /rest/api/3/issue/{key}/comment`, `GET·POST /rest/api/3/issue/{key}/transitions`(To Do→할 일 · In Progress→진행 중 · 완료하기→완료 · Hold→On Hold), `POST /rest/api/3/issue/{key}/comment`(문단 ADF만 — 빈 text 노드는 400), `GET /rest/api/3/issue/createmeta/{project}/issuetypes`(Task·Bug·Epic·Sub-task), `POST /rest/api/3/issue`.
- `POST /__config {write_fail: "401"|"403"|"400"|"500"|"drop"|"500_after"|"drop_after"|null, write_delay: 초}`, `GET /__jira`(이슈 상태·댓글·쓰기 기록). `POST /__reset`은 이슈·설정도 처음으로 되돌린다.
