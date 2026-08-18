#!/usr/bin/env bash
#
# fetch-launch-data-jira.sh
#
# MVP Jira Product Discovery fetch script. Pulls "Idea" issues from the IDEA
# project via JQL and reshapes them into the same launch-data-summary.json
# schema that .github/workflows/launch-readiness.md expects.
#
# This is intentionally minimal:
#   - No sub-issue / delivery-task walking (subIssues is always [])
#   - No completeness stats (stats is always zeroed)
#   - state is always "OPEN" (not distinguishing Roll Out from other stages yet)
#   - riskLevel is a placeholder ("Medium") since Jira has no native risk field
#
# Requires env vars: JIRA_EMAIL, JIRA_API_TOKEN, JIRA_BASE_URL
# Usage: ./fetch-launch-data-jira.sh <output-file>
#   e.g. ./fetch-launch-data-jira.sh launch-data-summary.json

set -euo pipefail

OUTPUT_FILE="${1:-launch-data-summary.json}"

: "${JIRA_EMAIL:?JIRA_EMAIL is required}"
: "${JIRA_API_TOKEN:?JIRA_API_TOKEN is required}"
: "${JIRA_BASE_URL:?JIRA_BASE_URL is required}"

# Custom field IDs discovered from Lirvana Labs' Jira instance:
#   customfield_10133 = Goal (multi-select)
#   customfield_10134 = Roadmap (single-select)
#   customfield_10144 = Project start/target (stored as JSON string: {"start":"...","end":"..."})
#   customfield_10153 = Idea Type (single-select, e.g. "Feature Epic", "Single Story")
#   customfield_10155 = Engineers (multi-user picker)
#   customfield_10156 = Designers (multi-user picker)
#   customfield_10127 = Combined Score-ish numeric field (best-effort; verify before trusting)
GOAL_FIELD="customfield_10133"
ROADMAP_FIELD="customfield_10134"
DATES_FIELD="customfield_10144"
IDEA_TYPE_FIELD="customfield_10153"
ENGINEERS_FIELD="customfield_10155"
DESIGNERS_FIELD="customfield_10156"
SCORE_FIELD="customfield_10127"

FIELDS="summary,status,updated,${IDEA_TYPE_FIELD},${DATES_FIELD},${ENGINEERS_FIELD},${DESIGNERS_FIELD},${SCORE_FIELD},${GOAL_FIELD},${ROADMAP_FIELD}"

JQL='project = IDEA AND issuetype = Idea AND "Roadmap" = "Now" AND cf[10133] in ("Operations/Lantau/Basecamp", "MC", "ConvAI", "Copilot", "YCK", "Station")'

echo "Fetching Ideas from Jira..." >&2

TMP_RAW="$(mktemp)"
trap 'rm -f "$TMP_RAW"' EXIT

PAGE_SIZE=100
ALL_ISSUES="[]"
NEXT_TOKEN=""
FETCHED=0

while true; do
  if [ -z "$NEXT_TOKEN" ]; then
    RESPONSE=$(curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
      -G "${JIRA_BASE_URL}/rest/api/3/search/jql" \
      --data-urlencode "jql=${JQL}" \
      --data-urlencode "fields=${FIELDS}" \
      --data-urlencode "maxResults=${PAGE_SIZE}")
  else
    RESPONSE=$(curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
      -G "${JIRA_BASE_URL}/rest/api/3/search/jql" \
      --data-urlencode "jql=${JQL}" \
      --data-urlencode "fields=${FIELDS}" \
      --data-urlencode "maxResults=${PAGE_SIZE}" \
      --data-urlencode "nextPageToken=${NEXT_TOKEN}")
  fi

  if echo "$RESPONSE" | jq -e '.errorMessages' >/dev/null 2>&1; then
    echo "Jira API error:" >&2
    echo "$RESPONSE" | jq '.errorMessages' >&2
    exit 1
  fi

  PAGE_ISSUES=$(echo "$RESPONSE" | jq '.issues')
  ALL_ISSUES=$(jq -s '.[0] + .[1]' <(echo "$ALL_ISSUES") <(echo "$PAGE_ISSUES"))

  RETURNED=$(echo "$PAGE_ISSUES" | jq 'length')
  FETCHED=$((FETCHED + RETURNED))
  echo "  fetched ${FETCHED} so far..." >&2

  NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.nextPageToken // empty')

  if [ -z "$NEXT_TOKEN" ] || [ "$RETURNED" -eq 0 ]; then
    break
  fi
done

echo "$ALL_ISSUES" > "$TMP_RAW"

echo "Reshaping into launch-data-summary.json schema..." >&2

jq \
  --arg baseUrl "$JIRA_BASE_URL" \
  --arg datesField "$DATES_FIELD" \
  --arg ideaTypeField "$IDEA_TYPE_FIELD" \
  --arg engineersField "$ENGINEERS_FIELD" \
  --arg scoreField "$SCORE_FIELD" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
  {
    generatedAt: $generatedAt,
    totalItems: length,
    launches: [
      .[] | {
        number: .key,
        title: .fields.summary,
        state: "OPEN",
        url: ($baseUrl + "/browse/" + .key),
        phase: (.fields.status.name // "Unknown"),
        targetDate: (
          .fields[$datesField] as $d |
          if $d and $d != "" then
            ($d | fromjson | .end // .start // null)
          else null end
        ),
        launchType: (.fields[$ideaTypeField].value // "Unlabeled"),
        riskLevel: "Medium",
        assignees: [
          (.fields[$engineersField] // [])[] | .displayName
        ],
        labels: [],
        subIssues: [],
        stats: {
          totalTasks: 0,
          closedTasks: 0,
          totalEpics: 0,
          closedEpics: 0
        },
        combinedScore: (.fields[$scoreField] // null),
        lastUpdated: .fields.updated
      }
    ],
    initiatives: []
  }
  ' "$TMP_RAW" > "$OUTPUT_FILE"

echo "Wrote $(jq '.totalItems' "$OUTPUT_FILE") ideas to $OUTPUT_FILE" >&2