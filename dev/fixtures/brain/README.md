# 사서(v0.5) 고정 자료 (가상의 내용)

docs/V05.md §10.1. 시험은 스크래치에 복사해서 쓰고 원본은 고치지 않는다.

- `vault/` — 작은 PARA 볼트(CLAUDE.md 트리 블록·ADR/TN 규칙·동결 폴더, `_workspace/` 이동 대상, AI 보관본, 데일리, PROGRESS, 캔버스, `.obsidian/workspace.json`).
- `claude/<프로젝트>/<uuid>.jsonl` — 가짜 Claude Code 세션. `-tmp-vault`는 볼트 안 작업(Write·Edit·MultiEdit, custom-title, 메타 줄, 키·메일·URL·주민번호 꼴 요청, 깨진 줄), `-tmp-code-payment-api`는 볼트 밖 코드 작업.
- `codex/2026/10/22/rollout-x.jsonl` — 가짜 Codex 세션(session_meta, 지시문 줄, 요청, apply_patch 새 형식·옛 형식).
- 세션 파일의 `{{VAULT}}`는 복사한 볼트의 절대 경로로 바꿔 쓴다. 세션 시각은 2026-10-22(UTC)이다.
  작성 주체 시험은 볼트 파일 수정 시각을 세션 쓰기 시각(±120초)에 맞춘다(`touch -t`). 시계는 SYNAPSE_NOW로 고정한다.
- 링크 시험용 자료는 `links/`(S2)에 따로 있다.
