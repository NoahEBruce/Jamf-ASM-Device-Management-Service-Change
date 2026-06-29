#!/bin/zsh

# Jamf Self Service workflow for changing an Apple School Manager device's
# assigned Device Management Service.

set -u

readonly APPLE_TOKEN_URL="https://account.apple.com/auth/oauth2/token"
readonly ASM_API_BASE_URL="https://api-school.apple.com/v1"
readonly GENERIC_FAILURE_MESSAGE="The site change could not be completed. Please contact a Jamf Admin."

# Jamf script parameters:
#   $4 = Apple OAuth client_id
#   $5 = Apple OAuth client_assertion
readonly CLIENT_ID="${4:-}"
readonly CLIENT_ASSERTION="${5:-}"

DIALOG_BIN=""
ACCESS_TOKEN=""
ADMIN_SERIAL=""
MDM_SERVERS_JSON=""
CURRENT_SERVER_JSON=""
SELECTED_SERVER_ID=""
SELECTED_SERVER_NAME=""
HTTP_BODY=""
HTTP_STATUS=""

TMP_FILES=()

cleanup() {
  local tmp_file
  for tmp_file in "${TMP_FILES[@]:-}"; do
    [[ -n "${tmp_file}" && -f "${tmp_file}" ]] && rm -f "${tmp_file}"
  done
}
trap cleanup EXIT

log_message() {
  # Keep Jamf logs useful without writing credentials or bearer tokens.
  printf '%s\n' "$1"
}

show_error() {
  local detail="${1:-}"

  if [[ -n "${detail}" ]]; then
    log_message "ASM Site Change failed: ${detail}"
  else
    log_message "ASM Site Change failed."
  fi

  if [[ -n "${DIALOG_BIN}" && -x "${DIALOG_BIN}" ]]; then
    "${DIALOG_BIN}" \
      --title "ASM Site Change" \
      --message "${GENERIC_FAILURE_MESSAGE}" \
      --button1text "OK" \
      --icon "SF=xmark.circle.fill,colour=red" \
      --moveable \
      --ontop >/dev/null 2>&1
  fi
}

show_info() {
  local title="$1"
  local message="$2"
  local icon="${3:-SF=info.circle,colour=blue}"

  "${DIALOG_BIN}" \
    --title "${title}" \
    --message "${message}" \
    --button1text "OK" \
    --icon "${icon}" \
    --moveable \
    --ontop >/dev/null 2>&1
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

json_error_summary() {
  local body="$1"

  if [[ -z "${body}" ]]; then
    printf 'No response body returned.'
    return 0
  fi

  if /usr/bin/printf '%s' "${body}" | jq -e . >/dev/null 2>&1; then
    /usr/bin/printf '%s' "${body}" | jq -r '
      if (.errors | type) == "array" then
        [.errors[] | [
          .status,
          .code,
          .title,
          .detail
        ] | map(select(. != null and . != "")) | join(" - ")] | join("; ")
      elif .error_description then
        .error_description
      elif .error then
        .error
      else
        "No Apple error detail returned."
      end
    ' 2>/dev/null
  else
    printf 'Non-JSON response returned.'
  fi
}

extract_body_and_status() {
  local response="$1"
  local http_status body

  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "${http_status}" == "${response}" ]]; then
    http_status="000"
    body="${response}"
  fi

  HTTP_BODY="${body}"
  HTTP_STATUS="${http_status}"
}

api_get() {
  local url="$1"
  local response body http_status error_detail

  response="$(curl -sS \
    --request GET \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json" \
    --write-out $'\n%{http_code}' \
    "${url}" 2>/dev/null)"

  extract_body_and_status "${response}"
  body="${HTTP_BODY}"
  http_status="${HTTP_STATUS}"

  if [[ ! "${http_status}" =~ ^2 ]]; then
    error_detail="$(json_error_summary "${body}")"
    log_message "Apple School Manager API GET failed with HTTP ${http_status}: ${error_detail}"
    return 1
  fi

  printf '%s' "${body}"
}

api_post_json() {
  local url="$1"
  local payload="$2"
  local response body http_status error_detail

  response="$(printf '%s' "${payload}" | curl -sS \
    --request POST \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json" \
    --header "Content-Type: application/json" \
    --data-binary @- \
    --write-out $'\n%{http_code}' \
    "${url}" 2>/dev/null)"

  extract_body_and_status "${response}"
  body="${HTTP_BODY}"
  http_status="${HTTP_STATUS}"

  if [[ "${http_status}" != "201" ]]; then
    error_detail="$(json_error_summary "${body}")"
    log_message "Apple School Manager API POST failed with HTTP ${http_status}: ${error_detail}"
    return 1
  fi

  printf '%s' "${body}"
}

validate_prerequisites() {
  if [[ -x "/usr/local/bin/dialog" ]]; then
    DIALOG_BIN="/usr/local/bin/dialog"
  elif [[ -x "/opt/homebrew/bin/dialog" ]]; then
    DIALOG_BIN="/opt/homebrew/bin/dialog"
  else
    log_message "swiftDialog is not installed."
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    show_error "jq is not installed."
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    show_error "curl is not available."
    return 1
  fi

  if [[ -z "${CLIENT_ID}" || -z "${CLIENT_ASSERTION}" ]]; then
    show_error "Missing required Jamf script parameters."
    return 1
  fi

  return 0
}

get_serial_from_admin() {
  local output_file dialog_exit serial

  output_file="$(mktemp "/tmp/asm-site-change-serial.XXXXXX")"
  TMP_FILES+=("${output_file}")

  "${DIALOG_BIN}" \
    --title "ASM Site Change" \
    --message "Enter the Apple School Manager device serial number or organization device ID." \
    --textfield "Serial Number,required" \
    --button1text "Continue" \
    --button2text "Cancel" \
    --icon "SF=desktopcomputer,colour=blue" \
    --json \
    --moveable \
    --ontop >"${output_file}"
  dialog_exit=$?

  if [[ "${dialog_exit}" -ne 0 ]]; then
    log_message "Admin cancelled serial entry."
    exit 0
  fi

  serial="$(jq -r '.["Serial Number"] // .SerialNumber // .serialNumber // empty' "${output_file}" | xargs)"

  if [[ -z "${serial}" ]]; then
    show_error "Blank serial number entered."
    return 1
  fi

  ADMIN_SERIAL="${serial}"
  return 0
}

get_access_token() {
  local encoded_client_id encoded_client_assertion form_body response body http_status error_detail token

  encoded_client_id="$(urlencode "${CLIENT_ID}")"
  encoded_client_assertion="$(urlencode "${CLIENT_ASSERTION}")"

  if [[ -z "${encoded_client_id}" || -z "${encoded_client_assertion}" ]]; then
    show_error "Could not encode Apple OAuth request."
    return 1
  fi

  form_body="grant_type=client_credentials&client_id=${encoded_client_id}&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=${encoded_client_assertion}&scope=school.api"

  response="$(printf '%s' "${form_body}" | curl -sS \
    --request POST \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Accept: application/json" \
    --data-binary @- \
    --write-out $'\n%{http_code}' \
    "${APPLE_TOKEN_URL}" 2>/dev/null)"

  extract_body_and_status "${response}"
  body="${HTTP_BODY}"
  http_status="${HTTP_STATUS}"

  if [[ ! "${http_status}" =~ ^2 ]]; then
    error_detail="$(json_error_summary "${body}")"
    log_message "Apple OAuth token request failed with HTTP ${http_status}: ${error_detail}"
    return 1
  fi

  token="$(printf '%s' "${body}" | jq -r '.access_token // empty' 2>/dev/null)"
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    show_error "Apple OAuth token response did not include an access token."
    return 1
  fi

  ACCESS_TOKEN="${token}"
  return 0
}

get_mdm_servers() {
  local url response combined next_url server_count

  url="${ASM_API_BASE_URL}/mdmServers?limit=1000&fields%5BmdmServers%5D=serverName,serverType,status"
  combined='[]'

  while [[ -n "${url}" && "${url}" != "null" ]]; do
    response="$(api_get "${url}")" || return 1

    combined="$(jq -n \
      --argjson existing "${combined}" \
      --argjson page "$(printf '%s' "${response}" | jq '.data // []')" \
      '$existing + $page')"

    next_url="$(printf '%s' "${response}" | jq -r '.links.next // empty')"
    url="${next_url}"
  done

  server_count="$(printf '%s' "${combined}" | jq 'length')"
  if [[ "${server_count}" -eq 0 ]]; then
    show_error "No Apple School Manager Device Management Services were returned."
    return 1
  fi

  MDM_SERVERS_JSON="${combined}"
  return 0
}

get_current_assigned_server() {
  local encoded_id response

  encoded_id="$(urlencode "${ADMIN_SERIAL}")"
  if [[ -z "${encoded_id}" ]]; then
    show_error "Could not encode entered device identifier."
    return 1
  fi

  response="$(api_get "${ASM_API_BASE_URL}/orgDevices/${encoded_id}/assignedServer?fields%5BmdmServers%5D=serverName,serverType")" || return 1

  if ! printf '%s' "${response}" | jq -e '.data.id and .data.attributes.serverName' >/dev/null 2>&1; then
    show_error "Assigned Device Management Service response was incomplete."
    return 1
  fi

  CURRENT_SERVER_JSON="$(printf '%s' "${response}" | jq -c '.data')"
  return 0
}

show_server_selection() {
  local current_id current_name values output_file dialog_exit selected_label selected_id selected_name

  current_id="$(printf '%s' "${CURRENT_SERVER_JSON}" | jq -r '.id')"
  current_name="$(printf '%s' "${CURRENT_SERVER_JSON}" | jq -r '.attributes.serverName')"

  values="$(printf '%s' "${MDM_SERVERS_JSON}" | jq -r '
    map(
      "\(.attributes.serverName | gsub(","; " ")) [\(.id)]"
    ) | join(",")
  ')"

  output_file="$(mktemp "/tmp/asm-site-change-select.XXXXXX")"
  TMP_FILES+=("${output_file}")

  "${DIALOG_BIN}" \
    --title "ASM Site Change" \
    --message "Device: ${ADMIN_SERIAL}\n\nCurrent Device Management Service: ${current_name}" \
    --selecttitle "Target Device Management Service" \
    --selectvalues "${values}" \
    --button1text "Continue" \
    --button2text "Cancel" \
    --icon "SF=arrow.triangle.2.circlepath.circle,colour=blue" \
    --json \
    --moveable \
    --ontop >"${output_file}"
  dialog_exit=$?

  if [[ "${dialog_exit}" -ne 0 ]]; then
    log_message "Admin cancelled Device Management Service selection."
    exit 0
  fi

  selected_label="$(jq -r '
    [
      .["Target Device Management Service"],
      .SelectedOption,
      .selectedOption,
      .selectValue,
      .selectedValue,
      .selectvalues,
      .selectValues,
      (.. | strings)
    ]
    | map(select(. != null and . != ""))[0] // empty
  ' "${output_file}")"

  selected_id="$(printf '%s' "${selected_label}" | sed -n 's/^.*\[\([^][]*\)\]$/\1/p')"

  if [[ -z "${selected_id}" ]]; then
    selected_id="$(jq -r --arg selected "${selected_label}" '
      .[]
      | select(.id == $selected or .attributes.serverName == $selected)
      | .id
    ' <<<"${MDM_SERVERS_JSON}")"
  fi

  if [[ -z "${selected_id}" ]]; then
    selected_id="$(jq -r --argjson dialog_output "$(cat "${output_file}")" '
      [ $dialog_output | .. | strings ] as $dialog_strings
      | .[]
      | . as $server
      | select(
          ($dialog_strings | index($server.id)) or
          ($dialog_strings | index($server.attributes.serverName)) or
          any($dialog_strings[]; contains($server.id))
        )
      | .id
    ' <<<"${MDM_SERVERS_JSON}" | head -n 1)"
  fi

  if [[ -z "${selected_id}" ]]; then
    show_error "No target Device Management Service selected."
    return 1
  fi

  selected_name="$(printf '%s' "${MDM_SERVERS_JSON}" | jq -r --arg id "${selected_id}" '.[] | select(.id == $id) | .attributes.serverName')"
  if [[ -z "${selected_name}" ]]; then
    show_error "Selected Device Management Service was not found in the API response."
    return 1
  fi

  SELECTED_SERVER_ID="${selected_id}"
  SELECTED_SERVER_NAME="${selected_name}"

  log_message "Selected target Device Management Service: ${SELECTED_SERVER_NAME} (${SELECTED_SERVER_ID})."

  if [[ "${SELECTED_SERVER_ID}" == "${current_id}" ]]; then
    show_info \
      "ASM Site Change" \
      "No change was made.\n\nThe selected Device Management Service is already assigned to ${ADMIN_SERIAL}." \
      "SF=checkmark.circle.fill,colour=green"
    exit 0
  fi

  return 0
}

confirm_change() {
  local current_name dialog_exit cancel_exit

  current_name="$(printf '%s' "${CURRENT_SERVER_JSON}" | jq -r '.attributes.serverName')"

  while true; do
    "${DIALOG_BIN}" \
      --title "Confirm ASM Site Change" \
      --message "Device: ${ADMIN_SERIAL}\n\nCurrent Device Management Service: ${current_name}\n\nTarget Device Management Service: ${SELECTED_SERVER_NAME}" \
      --button1text "Yes, Submit Change" \
      --button2text "Cancel" \
      --icon "SF=exclamationmark.triangle.fill,colour=orange" \
      --moveable \
      --ontop >/dev/null 2>&1
    dialog_exit=$?

    if [[ "${dialog_exit}" -eq 0 ]]; then
      return 0
    fi

    log_message "Admin cancelled confirmation."

    "${DIALOG_BIN}" \
      --title "ASM Site Change" \
      --message "Do you want to return to the Device Management Service selection screen or exit without making changes?" \
      --button1text "Return to Selection" \
      --button2text "Exit" \
      --icon "SF=questionmark.circle,colour=blue" \
      --moveable \
      --ontop >/dev/null 2>&1
    cancel_exit=$?

    if [[ "${cancel_exit}" -eq 0 ]]; then
      return 2
    fi

    exit 0
  done
}

assign_device_to_server() {
  local payload response activity_id activity_status

  payload="$(jq -n \
    --arg server_id "${SELECTED_SERVER_ID}" \
    --arg device_id "${ADMIN_SERIAL}" \
    '{
      data: {
        type: "orgDeviceActivities",
        attributes: {
          activityType: "ASSIGN_DEVICES"
        },
        relationships: {
          mdmServer: {
            data: {
              type: "mdmServers",
              id: $server_id
            }
          },
          devices: {
            data: [
              {
                type: "orgDevices",
                id: $device_id
              }
            ]
          }
        }
      }
    }')"

  response="$(api_post_json "${ASM_API_BASE_URL}/orgDeviceActivities" "${payload}")" || return 1

  activity_id="$(printf '%s' "${response}" | jq -r '.data.id // empty')"
  activity_status="$(printf '%s' "${response}" | jq -r '.data.attributes.status // empty')"

  show_info \
    "ASM Site Change Submitted" \
    "Apple School Manager accepted the site change for ${ADMIN_SERIAL}.\n\nTarget Device Management Service: ${SELECTED_SERVER_NAME}\n\nActivity ID: ${activity_id:-Unavailable}\nStatus: ${activity_status:-Submitted}" \
    "SF=checkmark.circle.fill,colour=green"

  log_message "ASM Site Change submitted for device ${ADMIN_SERIAL}; activity ID ${activity_id:-unavailable}; status ${activity_status:-submitted}."
  return 0
}

main() {
  local confirm_result

  validate_prerequisites || exit 1

  # Prompt the admin for the target Apple School Manager device identifier.
  get_serial_from_admin || exit 1

  # Exchange the Jamf-supplied OAuth client credentials for an access token.
  get_access_token || {
    show_error "Unable to obtain Apple OAuth access token."
    exit 1
  }

  # Retrieve all available Apple School Manager Device Management Services.
  get_mdm_servers || {
    show_error "Unable to retrieve Device Management Services."
    exit 1
  }

  # Retrieve the target device's current assigned Device Management Service.
  get_current_assigned_server || {
    show_error "Unable to retrieve current assigned Device Management Service."
    exit 1
  }

  while true; do
    # Let the admin choose the destination Device Management Service.
    show_server_selection || exit 1

    # Confirm the intended change before submitting the activity.
    confirm_change
    confirm_result=$?

    if [[ "${confirm_result}" -eq 0 ]]; then
      break
    elif [[ "${confirm_result}" -eq 2 ]]; then
      continue
    else
      exit 1
    fi
  done

  # Submit the Apple School Manager assignment activity.
  assign_device_to_server || {
    show_error "Unable to submit Device Management Service assignment."
    exit 1
  }

  exit 0
}

main "$@"
