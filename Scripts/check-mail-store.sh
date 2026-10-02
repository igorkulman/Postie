#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$(mktemp -d -t imail-checks)"
trap 'rm -rf "$output"' EXIT
swiftc -parse-as-library -default-isolation MainActor \
    iMail/Models/MailModels.swift \
    iMail/Models/MailStore.swift \
    iMail/Models/SampleMail.swift \
    Tests/MailStoreChecks.swift \
    -o "$output/MailStoreChecks"
"$output/MailStoreChecks"
