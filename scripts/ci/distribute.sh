#!/usr/bin/env bash
# Manual GitHub-hosted macOS archive/export. This script never uploads to Apple.
set +x
set -euo pipefail
umask 077

mode=${1:-build}
[[ "$mode" == build || "$mode" == cleanup ]] || { echo 'Usage: distribute.sh build|cleanup' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && ${GITHUB_ACTIONS:-} == true && ${GITHUB_REF:-} == refs/heads/main ]] || {
  echo 'Distribution requires a GitHub Actions macOS runner on main.' >&2; exit 1;
}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
work="${RUNNER_TEMP:?}/pairnotes-distribution-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
keychain="$work/signing.keychain-db"

cleanup() {
  [[ -d "$work" ]] || return 0
  python3 - "$work" "$root" <<'PY'
import json, pathlib, shutil, subprocess, sys
work, root = map(pathlib.Path, sys.argv[1:])
state_path = work / 'cleanup.json'
if state_path.exists():
    state = json.loads(state_path.read_text())
    if 'keychains' in state:
        subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *state['keychains']], check=True)
    keychain = work / 'signing.keychain-db'
    if keychain.exists():
        subprocess.run(['security', 'delete-keychain', str(keychain)], check=True)
    for path in state['profiles']:
        pathlib.Path(path).unlink(missing_ok=True)
    for name in state['config']:
        (root / 'Config' / name).unlink(missing_ok=True)
shutil.rmtree(work)
PY
}

if [[ "$mode" == cleanup ]]; then
  cleanup
  exit 0
fi
[[ ! -e "$work" ]] || { echo 'Signing workspace already exists; run cleanup first.' >&2; exit 1; }
mkdir -p "$work" artifacts/distribution
finish() {
  local result=$?
  trap - EXIT
  cleanup || result=1
  exit "$result"
}
trap finish EXIT

# Decode directly from environment; neither values nor private assets enter build logs.
python3 - "$work" <<'PY'
import base64, json, os, pathlib, shlex, subprocess, sys
work = pathlib.Path(sys.argv[1])
names = ['Local.xcconfig', 'App.local.entitlements', 'Widget.local.entitlements']
if any((pathlib.Path('Config') / name).exists() for name in names):
    raise SystemExit('Refusing to overwrite existing local configuration or entitlements.')
state = {'config': names, 'profiles': [], 'keychains': shlex.split(
    subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))}
(work / 'cleanup.json').write_text(json.dumps(state))
for secret, name in [('PAIRNOTES_DISTRIBUTION_P12_BASE64', 'distribution.p12'),
                     ('PAIRNOTES_APP_PROFILE_BASE64', 'app.mobileprovision'),
                     ('PAIRNOTES_WIDGET_PROFILE_BASE64', 'widget.mobileprovision')]:
    value = os.environ.get(secret, '')
    if not value:
        raise SystemExit(f'Missing GitHub secret: {secret}')
    try:
        (work / name).write_bytes(base64.b64decode(''.join(value.split()), validate=True))
    except ValueError:
        raise SystemExit(f'Invalid Base64 secret: {secret}') from None
config = os.environ.get('PAIRNOTES_IOS_CONFIG', '')
if not config.strip() or not os.environ.get('PAIRNOTES_DISTRIBUTION_P12_PASSWORD'):
    raise SystemExit('Missing PAIRNOTES_IOS_CONFIG or P12 password secret.')
pathlib.Path('Config/Local.xcconfig').write_text(config + '\n')
for target in ['App', 'Widget']:
    pathlib.Path(f'Config/{target}.local.entitlements').write_bytes(
        pathlib.Path(f'Config/{target}.entitlements.example').read_bytes())
PY

keychain_password=$(openssl rand -hex 32)
echo "::add-mask::$keychain_password"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
if ! security import "$work/distribution.p12" -P "$PAIRNOTES_DISTRIBUTION_P12_PASSWORD" \
    -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security > "$work/import.log" 2>&1; then
  echo 'P12 import failed. Check its password and macOS compatibility; re-export the identity if needed. No legacy conversion was attempted.' >&2
  exit 1
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
unset keychain_password PAIRNOTES_DISTRIBUTION_P12_PASSWORD PAIRNOTES_DISTRIBUTION_P12_BASE64
unset PAIRNOTES_APP_PROFILE_BASE64 PAIRNOTES_WIDGET_PROFILE_BASE64 PAIRNOTES_IOS_CONFIG
security find-identity -v -p codesigning "$keychain" > "$work/identities.txt"
security cms -D -i "$work/app.mobileprovision" > "$work/app.plist"
security cms -D -i "$work/widget.mobileprovision" > "$work/widget.plist"

# Validate the two profiles, then install only the selected UUIDs in Xcode's current directory.
python3 - "$work" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, re, shutil, subprocess, sys
work = pathlib.Path(sys.argv[1])
team, app = '2K2U374CJC', 'com.niiihuel.pairnotes'
state_path = work / 'cleanup.json'
state = json.loads(state_path.read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', str(work / 'signing.keychain-db'), *state['keychains']], check=True)
identities = set(re.findall(r'\b([A-Fa-f0-9]{40}) "Apple Distribution:[^"\n]+"', (work / 'identities.txt').read_text()))
identities = {value.upper() for value in identities}
profiles = {}
prefixes = set()
for target, bundle in [('app', app), ('widget', app + '.widgets')]:
    profile = plistlib.loads((work / f'{target}.plist').read_bytes())
    entitlements = profile.get('Entitlements', {})
    prefix = profile.get('ApplicationIdentifierPrefix', [''])[0]
    valid = (team in profile.get('TeamIdentifier', []) and prefix
             and entitlements.get('application-identifier') == f'{prefix}.{bundle}'
             and entitlements.get('com.apple.developer.team-identifier') == team
             and entitlements.get('aps-environment') == 'production'
             and not entitlements.get('get-task-allow', False)
             and not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices', False)
             and profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
             and re.fullmatch(r'[A-Fa-f0-9-]{36}', profile.get('UUID', '')))
    if not valid:
        raise SystemExit(f'{target}: expected a current App Store profile for the configured team and bundle ID.')
    certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
    identities &= certificates
    profiles[bundle] = profile['UUID']
    prefixes.add(prefix)
    (work / f'{target}.uuid').write_text(profile['UUID'])
if len(identities) != 1 or len(prefixes) != 1:
    raise SystemExit('Both profiles must share one valid imported Apple Distribution identity and App ID prefix.')
directory = pathlib.Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
directory.mkdir(parents=True, exist_ok=True)
for target, bundle in [('app', app), ('widget', app + '.widgets')]:
    destination = directory / f'{profiles[bundle]}.mobileprovision'
    if destination.exists():
        raise SystemExit('Refusing to overwrite a pre-existing provisioning profile.')
    state['profiles'].append(str(destination))
    state_path.write_text(json.dumps(state))
    shutil.copyfile(work / f'{target}.mobileprovision', destination)
options = {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'manual',
           'teamID': team, 'signingCertificate': next(iter(identities)), 'provisioningProfiles': profiles,
           'manageAppVersionAndBuildNumber': False, 'uploadSymbols': False}
(work / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
print('Validated App Store profiles and their shared signing identity.')
PY

build_number="${GITHUB_RUN_NUMBER:?}.${GITHUB_RUN_ATTEMPT}"
[[ "$build_number" =~ ^[0-9]+\.[0-9]+$ ]] || { echo 'Invalid build number.' >&2; exit 1; }
settings=(
  CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' DEVELOPMENT_TEAM=2K2U374CJC
  "PAIRNOTES_APP_PROFILE_SPECIFIER=$(cat "$work/app.uuid")"
  "PAIRNOTES_WIDGET_PROFILE_SPECIFIER=$(cat "$work/widget.uuid")"
  MARKETING_VERSION=1.0 "CURRENT_PROJECT_VERSION=$build_number"
  PAIRNOTES_APNS_ENVIRONMENT=production
)
# The static framework keeps its target-level CODE_SIGNING_ALLOWED=NO.
xcodebuild -project PairNotes.xcodeproj -scheme PairNotes -configuration Release \
  -onlyUsePackageVersionsFromResolvedFile \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$work/DerivedData" \
  -archivePath "$work/PairNotes.xcarchive" "${settings[@]}" archive \
  2>&1 | tee artifacts/distribution/archive.log
git diff --exit-code -- PairNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -exportArchive -archivePath "$work/PairNotes.xcarchive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" \
  2>&1 | tee artifacts/distribution/export.log

shopt -s nullglob
ipas=("$work/export/"*.ipa)
[[ ${#ipas[@]} == 1 ]] || { echo 'Expected exactly one exported IPA.' >&2; exit 1; }
ditto -x -k "${ipas[0]}" "$work/verify"
codesign --verify --deep --strict "$work/verify/Payload/PairNotes.app"
codesign --verify --strict "$work/verify/Payload/PairNotes.app/PlugIns/PairNotesWidgets.appex"
python3 - "$work" "$build_number" <<'PY'
import json, pathlib, plistlib, re, subprocess, sys, urllib.parse
work, build = pathlib.Path(sys.argv[1]), sys.argv[2]
app_id, group = 'com.niiihuel.pairnotes', 'group.com.niiihuel.pairnotes'
app = work / 'verify/Payload/PairNotes.app'
def require(condition, description):
    if not condition:
        raise SystemExit(f'Export verification failed: {description}')
for target, bundle, identifier in [('app', app, app_id), ('widget', app / 'PlugIns/PairNotesWidgets.appex', app_id + '.widgets')]:
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')]))
    entitlements = plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)],
                                               check=True, capture_output=True).stdout)
    prefix = profile['ApplicationIdentifierPrefix'][0]
    shared, private = f'{prefix}.{app_id}.shared', f'{prefix}.{app_id}'
    require(profile['UUID'] == (work / f'{target}.uuid').read_text(), f'{target} profile UUID')
    require(info['CFBundleIdentifier'] == identifier and info['CFBundleShortVersionString'] == '1.0'
            and info['CFBundleVersion'] == build, f'{target} bundle ID and version')
    require(entitlements.get('application-identifier') == f'{prefix}.{identifier}'
            and entitlements.get('com.apple.developer.team-identifier') == '2K2U374CJC', f'{target} signed identity')
    require(entitlements.get('aps-environment') == info.get('PAIRNOTES_APNS_ENVIRONMENT') == 'production'
            and not entitlements.get('get-task-allow', False), f'{target} production entitlements')
    require(entitlements.get('com.apple.security.application-groups') == [group]
            and info.get('PAIRNOTES_APP_GROUP') == group, f'{target} App Group')
    require(entitlements.get('keychain-access-groups') == ([private, shared] if target == 'app' else [shared])
            and info.get('PAIRNOTES_KEYCHAIN_GROUP') == shared, f'{target} isolated Keychain groups')
    require((bundle / 'PrivacyInfo.xcprivacy').is_file(), f'{target} privacy manifest')
    plistlib.loads((bundle / 'PrivacyInfo.xcprivacy').read_bytes())
    if target == 'app':
        require(info.get('PAIRNOTES_PRIVATE_KEYCHAIN_GROUP') == private
                and entitlements.get('com.apple.developer.applesignin') == ['Default'], 'app private Keychain and Apple sign-in')
        url = urllib.parse.urlparse(info.get('PAIRNOTES_API_BASE_URL', ''))
        require(url.scheme == 'https' and url.hostname and not url.username and not url.password
                and not re.search(r'example|localhost|unconfigured|\$\(', url.geturl()), 'configured HTTPS API')
        client = info.get('PAIRNOTES_GOOGLE_CLIENT_ID', '')
        server = info.get('PAIRNOTES_GOOGLE_SERVER_CLIENT_ID', '')
        require(all(re.fullmatch(r'[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com', value)
                    for value in [client, server]), 'configured Google client IDs')
        schemes = [value for item in info.get('CFBundleURLTypes', []) for value in item.get('CFBundleURLSchemes', [])]
        require('.'.join(reversed(client.split('.'))) in schemes, 'Google callback scheme')
pathlib.Path('artifacts/distribution/verification.json').write_text(json.dumps({
    'app_and_widget_signatures_verified': True, 'bundle_ids_and_versions_verified': True,
    'embedded_profiles_verified': True, 'production_entitlements_verified': True,
    'keychain_isolation_verified': True, 'privacy_manifests_present': True,
    'api_and_google_configuration_present': True, 'uploaded_to_apple': False}, indent=2) + '\n')
PY
cp "${ipas[0]}" artifacts/distribution/PairNotes.ipa
tar -czf artifacts/distribution/PairNotes.dSYMs.tar.gz -C "$work/PairNotes.xcarchive" dSYMs
{
  echo "commit=${GITHUB_SHA:?}"
  echo "version=1.0 ($build_number)"
  echo 'method=app-store-connect; destination=export; uploaded_to_apple=false'
  xcodebuild -version
  shasum -a 256 artifacts/distribution/PairNotes.ipa
} > artifacts/distribution/build-info.txt
echo 'Signed IPA exported and signatures verified. No upload to Apple was performed.'
