# 볼트 지침 (Claude용)

이 볼트는 의사결정·학습을 기록하는 Second Brain이다. PARA 구조를 따른다.

## 폴더 구조

```
Vault/
├── _Inbox/                      ← 임시 수신함
├── _workspace/                  ← 작업 중 초안 (정리 대상)
├── _Templates/                  ← 템플릿 (읽기 전용)
├── 1-Projects/
│   ├── {프로젝트명}/
│   │   ├── CLAUDE.md
│   │   ├── PROGRESS.md
│   │   └── _workspace/          ← 프로젝트 초안
│   └── 정산-설계/                ← 동결, 참조용
├── 2-Areas/
│   └── {프로젝트명}/
│       ├── 프로젝트_요약.md
│       ├── 의사결정/ADR-XXX_제목.md
│       ├── 기술노트/TN-XXX_제목.md
│       └── 운영/
├── 3-Resources/
│   └── {주제별 폴더}/
└── 4-Archive/
```

## ADR (의사결정 기록)

- 파일명: `ADR-XXX_제목.md`
- 위치: `2-Areas/{프로젝트명}/의사결정/`
- ADR을 확정하면 프로젝트_요약.md의 의사결정 목록도 갱신한다.

## TN (기술노트)

- 파일명: `TN-XXX_제목.md`
- 위치: `2-Areas/{프로젝트명}/기술노트/`

## 그 밖

- `_ref/`와 `_Templates/`는 건드리지 않는다.
- 진행 상황은 프로젝트 폴더의 PROGRESS.md에 적는다.
