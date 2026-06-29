# Jamf ASM Device Management Service Change

Jamf Self Service script using swiftDialog and the Apple School Manager API to change a device’s assigned Device Management Service.

## Overview

This workflow lets an IT admin manually enter an Apple School Manager device identifier, view the currently assigned Device Management Service, and move the device to another available Device Management Service.

Some organizations may use Device Management Service assignments to represent sites, locations, or enrollment destinations.

## Requirements

- Jamf Pro
- swiftDialog installed on managed Macs
- jq installed on managed Macs
- Apple School Manager API credentials with access to `school.api`

## Jamf Script Parameters

- Parameter 4: Apple API `client_id`
- Parameter 5: Apple API `client_assertion`

Do not hardcode credentials in the script.

## Workflow

1. Admin enters the target device serial number / orgDevice ID.
2. Script requests an Apple OAuth token.
3. Script retrieves available Device Management Services.
4. Script retrieves the current assigned Device Management Service.
5. Admin selects a target Device Management Service.
6. Admin confirms the change.
7. Script submits an `ASSIGN_DEVICES` activity to Apple School Manager.

## Safety

The script submits only the single device identifier manually entered by the admin. It does not enumerate or bulk-change devices.

## Apple API Endpoints Used

- `POST https://account.apple.com/auth/oauth2/token`
- `GET https://api-school.apple.com/v1/mdmServers`
- `GET https://api-school.apple.com/v1/orgDevices/{id}/assignedServer`
- `POST https://api-school.apple.com/v1/orgDeviceActivities`

## License

Add your preferred license.
