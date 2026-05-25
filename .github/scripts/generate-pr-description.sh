#!/usr/bin/env bash

set -euo pipefail

TARGET_BRANCH="$1"
SOURCE_BRANCH="$2"

if [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "GEMINI_API_KEY is not configured." >&2
  exit 1
fi

git fetch origin "$TARGET_BRANCH" --depth=1

MERGE_BASE=$(git merge-base "origin/$TARGET_BRANCH" HEAD)
COMMITS=$(git log --no-merges "$MERGE_BASE..HEAD" --oneline)
DIFF_STATS=$(git diff --stat "$MERGE_BASE..HEAD")
DIFF_CONTENT=$(git diff --unified=3 "$MERGE_BASE..HEAD" \
  -- . \
  ':(exclude)package-lock.json' \
  ':(exclude)yarn.lock' \
  ':(exclude)pnpm-lock.yaml' \
  ':(exclude)dist/**' \
  ':(exclude).gitignore')

if [ -z "$DIFF_CONTENT" ]; then
  {
    echo "should_create=false"
    echo "title=[chore] 변경 사항 없음"
    echo "body<<EOF"
    echo "변경 사항이 없어 PR을 생성하지 않습니다."
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

PR_TEMPLATE=$(cat .github/PULL_REQUEST_TEMPLATE.md)

PROMPT=$(cat <<EOF
당신은 GitHub Pull Request 제목과 본문 초안을 작성하는 한국어 기술 문서 작성자입니다.

목표:
- feature 브랜치에서 test 브랜치로 보내는 PR의 제목과 본문 초안을 생성합니다.
- 저장소 PR 템플릿의 섹션 구조를 유지한 상태로 각 항목을 초안 형태로 채웁니다.

제목 규칙:
- 반드시 한국어로 작성합니다.
- 형식은 "[type] 작업 내용"입니다.
- type은 feat, fix, refactor, chore, docs, test, ci 중 하나만 사용합니다.
- 60자 이내를 권장합니다.

본문 규칙:
- 반드시 한국어 마크다운으로 작성합니다.
- 변경 사항은 커밋 목록, 변경 파일 통계, 상세 diff에 근거해 작성합니다.
- 아래에 제공되는 PR 템플릿의 헤더 구조와 순서를 그대로 유지합니다.
- 확실하지 않은 내용은 추측하지 말고 "확인 필요" 또는 "직접 보완 필요"라고 적습니다.
- 테스트를 실제로 실행했다고 추정하지 않습니다.
- 각 섹션은 1~3개의 bullet로 짧고 선명하게 작성합니다.
- HTML 주석은 제거하고 실제 초안 문장을 작성합니다.

출력 형식:
TITLE: [feat] 예시 제목
---
아래 PR 템플릿 구조를 유지한 완성된 마크다운 본문

PR 정보:
- base branch: $TARGET_BRANCH
- head branch: $SOURCE_BRANCH

PR 템플릿:
---
$PR_TEMPLATE
---

커밋 목록:
$COMMITS

변경 파일 통계:
$DIFF_STATS

상세 diff:
$DIFF_CONTENT
EOF
)

REQUEST_BODY=$(jq -n --arg prompt "$PROMPT" '{
  contents: [
    {
      role: "user",
      parts: [{ text: $prompt }]
    }
  ],
  generationConfig: {
    temperature: 0.2
  }
}')

GEMINI_RESPONSE=""
for attempt in 1 2 3; do
  HTTP_RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "$REQUEST_BODY")

  HTTP_STATUS=$(printf '%s' "$HTTP_RESPONSE" | tail -n 1)
  GEMINI_RESPONSE=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')

  if [ "$HTTP_STATUS" = "200" ]; then
    break
  fi

  if [ "$attempt" -eq 3 ] || { [ "$HTTP_STATUS" != "429" ] && [ "${HTTP_STATUS#5}" = "$HTTP_STATUS" ]; }; then
    echo "Gemini API request failed with status $HTTP_STATUS" >&2
    echo "$GEMINI_RESPONSE" >&2
    exit 1
  fi

  sleep $((attempt * 2))
done

FULL_RESPONSE=$(printf '%s' "$GEMINI_RESPONSE" | jq -r '
  .candidates[0].content.parts
  | map(.text // "")
  | join("")
')

if [ -z "$FULL_RESPONSE" ] || [ "$FULL_RESPONSE" = "null" ]; then
  echo "Gemini API returned an empty response." >&2
  echo "$GEMINI_RESPONSE" >&2
  exit 1
fi

PR_TITLE=$(printf '%s\n' "$FULL_RESPONSE" | grep '^TITLE:' | sed 's/^TITLE: //')
PR_BODY_DRAFT=$(printf '%s\n' "$FULL_RESPONSE" | sed '1,/^---$/d')

if [ -z "$PR_TITLE" ] || [ -z "$PR_BODY_DRAFT" ]; then
  echo "Failed to parse Gemini response." >&2
  exit 1
fi

PR_BODY=$(cat <<EOF
$PR_BODY_DRAFT
EOF
)

TITLE_FILE=$(mktemp)
BODY_FILE=$(mktemp)

printf '%s' "$PR_TITLE" > "$TITLE_FILE"
printf '%s' "$PR_BODY" > "$BODY_FILE"

{
  echo "should_create=true"
  echo "title=$PR_TITLE"
  echo "title_file=$TITLE_FILE"
  echo "body_file=$BODY_FILE"
} >> "$GITHUB_OUTPUT"
