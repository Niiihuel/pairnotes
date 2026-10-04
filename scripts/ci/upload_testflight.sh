#!/usr/bin/env bash
# Upload only. Processing, encryption answers, testers and Store submission are separate.
set +x
set -euo pipefail
umask 077
mode=${1:-upload}
[[ "$mode" == upload || "$mode" == cleanup ]] || { echo 'Usage: upload_testflight.sh upload|cleanup' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && ${GITHUB_ACTIONS:-} == true && ${GITHUB_REF:-} == refs/heads/main ]] || {
  echo 'Upload requires a GitHub Actions macOS runner on main.' >&2; exit 1;
}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
work="${RUNNER_TEMP:?}/pairnotes-upload-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
cleanup() { rm -rf -- "$work"; }
if [[ "$mode" == cleanup ]]; then cleanup; exit 0; fi
[[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${PAIRNOTES_UPLOAD_TO_TESTFLIGHT:-} == true ]] || {
  echo 'Upload requires the explicit workflow_dispatch upload_to_testflight=true input.' >&2; exit 1;
}
[[ ! -e "$work" ]] || { echo 'Upload workspace already exists; run cleanup first.' >&2; exit 1; }
mkdir -p "$work"
trap cleanup EXIT

# Check the installed tool before accessing credentials. Never print authentication output.
xcrun altool --help > "$work/altool-help.txt" 2>&1
python3 - "$work" <<'PY'
import hashlib, json, os, pathlib, plistlib, re, sys, zipfile
work = pathlib.Path(sys.argv[1])
help_text = (work / 'altool-help.txt').read_text()
if not all(option in help_text for option in ['--upload-app', '--apiKey', '--apiIssuer']):
    raise SystemExit('Installed altool does not document the required upload/API key options.')
directory = pathlib.Path('artifacts/distribution')
verification = json.loads((directory / 'verification.json').read_text())
checks = ['app_and_widget_signatures_verified', 'bundle_ids_and_versions_verified',
          'embedded_profiles_verified', 'production_entitlements_verified', 'keychain_isolation_verified',
          'privacy_manifests_present', 'api_and_google_configuration_present']
if not all(verification.get(check) is True for check in checks):
    raise SystemExit('The exported IPA has not passed every distribution verification.')
ipa = directory / 'PairNotes.ipa'
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
build_info = (directory / 'build-info.txt').read_text()
if f'commit={os.environ["GITHUB_SHA"]}\n' not in build_info or f'{digest}  {ipa}' not in build_info:
    raise SystemExit('IPA digest or source commit does not match the verified export.')
with zipfile.ZipFile(ipa) as archive:
    info = plistlib.loads(archive.read('Payload/PairNotes.app/Info.plist'))
if (info.get('CFBundleIdentifier') != 'com.niiihuel.pairnotes' or info.get('CFBundleShortVersionString') != '1.0'
        or info.get('CFBundleVersion') != f'{os.environ["GITHUB_RUN_NUMBER"]}.{os.environ["GITHUB_RUN_ATTEMPT"]}'):
    raise SystemExit('IPA identity or version does not match this workflow run.')
key_id, issuer, key = (os.environ.get(name, '').strip() for name in
                      ['PAIRNOTES_ASC_KEY_ID', 'PAIRNOTES_ASC_ISSUER_ID', 'PAIRNOTES_ASC_PRIVATE_KEY'])
if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', issuer):
    raise SystemExit('Missing or invalid App Store Connect key ID / issuer ID secrets.')
if not key.startswith('-----BEGIN PRIVATE KEY-----\n') or not key.endswith('-----END PRIVATE KEY-----'):
    raise SystemExit('Missing or invalid App Store Connect private key secret (PEM expected).')
(work / f'AuthKey_{key_id}.p8').write_text(key + '\n')
print('Verified IPA and altool upload options; using a temporary API key file.')
PY
unset PAIRNOTES_ASC_PRIVATE_KEY
export API_PRIVATE_KEYS_DIR="$work"
upload_exit=0
xcrun altool --upload-app --type ios --file artifacts/distribution/PairNotes.ipa \
  --apiKey "$PAIRNOTES_ASC_KEY_ID" --apiIssuer "$PAIRNOTES_ASC_ISSUER_ID" \
  > "$work/upload-output.txt" 2>&1 || upload_exit=$?
unset PAIRNOTES_ASC_KEY_ID PAIRNOTES_ASC_ISSUER_ID API_PRIVATE_KEYS_DIR

# altool success is an upload receipt, not evidence that Apple finished processing.
# Keep only allowlisted indicators; raw authentication output is deleted with the key.
python3 - "$work/upload-output.txt" "$upload_exit" <<'PY'
import json, pathlib, re, sys
output = pathlib.Path(sys.argv[1]).read_text(errors='replace')
exit_code = int(sys.argv[2])
confirmed = bool(re.search(r'UPLOAD SUCCEEDED with no errors|No errors uploading', output))
errors = bool(re.search(r'\bERROR:|\*\*\* Error:|Failed to upload', output))
success = exit_code == 0 and confirmed and not errors
delivery = re.search(r'Delivery UUID:\s*([0-9a-fA-F-]{36})', output)
result = {'upload_status': 'upload_confirmed' if success else 'upload_failed_or_unconfirmed',
          'command_exit_code': exit_code, 'success_receipt_observed': confirmed,
          'error_observed': errors, 'delivery_uuid': delivery.group(1) if delivery else None,
          'error_codes': sorted({code for match in re.findall(r'\((-\d{3,6})\)|\b(ITMS-\d{4,6})\b', output)
                                 for code in match if code}),
          'apple_processing_status': 'not_checked', 'testflight_availability': 'not_checked',
          'tester_configuration_changed': False, 'store_submission_requested': False,
          'encryption_declaration_changed': False}
pathlib.Path('artifacts/distribution/upload-result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
if not success:
    raise SystemExit('Upload was not confirmed. Check the safe result and App Store Connect before retrying.')
PY
