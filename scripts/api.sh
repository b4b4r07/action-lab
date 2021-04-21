GITHUB_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN is required}
EVENT_ACTION=${EVENT_ACTION:?EVENT_ACTION is required}
GITHUB_REPO=${GITHUB_REPO:?GITHUB_REPO is required}
PULL_REQUEST_NUMBER=${PULL_REQUEST_NUMBER:?PULL_REQUEST_NUMBER is required}
GIST_ID=${GIST_ID:?GIST_ID is required}

ok_to_record() {
  local -i count
  local json

  json="$(get_pull_files | jq -r '.[] | select(.filename | endswith("module.tf")) | select(.status == "added")')"

  {
    local line
    echo "[DEBUG] ======== ok_to_record ========"
    echo "${json}" | while read line; do echo "[DEBUG] ${line}"; done
    echo "[DEBUG] =============================="
  } >&2

  count=$(echo "${json}" | jq -r .additions)

  if [[ ${count:-0} == 0 ]]; then
    return 1
  fi

  return 0
}

main() {
  local action
  action=${EVENT_ACTION}

  if ! ok_to_record; then
    return
  fi

  # https://docs.github.com/ja/developers/webhooks-and-events/github-event-types#pullrequestevent
  case "${action}" in
    "opened" | "reopened" | "synchronize")
      echo "[DEBUG] Run insert_record and update_db..."
      insert_record | update_db
      ;;

    "closed")
      # if [[ ${PULL_REQUEST_MERGED} == false ]]; then
      #   echo "[DEBUG] github.event.pull_request.merged is false, skipped to record"
      #   return
      # fi
      echo "[DEBUG] Run update_record and update_db..."
      local merged_at
      merged_at=$(get_pull | jq -r '.merged_at')
      update_record "merged_at" "${merged_at}" | update_db
      ;;

  esac
}

get_pull() {
  curl \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/${GITHUB_REPO}/pulls/${PULL_REQUEST_NUMBER}
}

get_pull_files() {
  curl \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/${GITHUB_REPO}/pulls/${PULL_REQUEST_NUMBER}/files
}

get_record() {
  curl \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/gists/${GIST_ID} \
    | jq -r '.files["pull_request.json"].content'
}

insert_record() {
  local created_at merged_at
  created_at=$(get_pull | jq -r '.created_at')
  merged_at=$(get_pull | jq -r '.merged_at')
  get_record | jq '.pull_requests += [
  {
    "number": '${PULL_REQUEST_NUMBER}',
    "created_at": "'${created_at}'",
    "merged_at": "'${merged_at}'"
  }]'
}

update_record() {
  local json k v
  local k=${1:?key which you update is required}
  local v=${2:?value which you update is required}
  get_record | jq '(.pull_requests[] | select(.number == '${PULL_REQUEST_NUMBER}') | .'${k}') |= "'${v}'"'
}

update_db() {
  local json
  json="$(jq 'tostring')"
  cat <<EOF |
{
  "files": {
    "pull_request.json": {
      "filename": "pull_request.json",
      "content": ${json}
    }
  }
}
EOF

  curl \
    -X PATCH \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/gists/${GIST_ID} \
    -d @-
}

set -e
main
