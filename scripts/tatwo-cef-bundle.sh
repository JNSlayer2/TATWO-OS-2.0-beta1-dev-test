#!/usr/bin/env bash

# Shared Chromium Embedded Framework runtime, bundle assembly, signing, and
# artifact verification for staging and the canonical local production App.
# Callers own the outer build lock and final top-level App signature.

if ! declare -F plist_string >/dev/null 2>&1; then
plist_string() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}
fi

if ! declare -F json_string >/dev/null 2>&1; then
json_string() {
  /usr/bin/python3 - "$1" "$2" <<'PYJSON'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for component in sys.argv[2].split("."):
    value = value[component]
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PYJSON
}
fi

if ! declare -F json_scalar >/dev/null 2>&1; then
json_scalar() {
  /usr/bin/python3 - "$1" "$2" <<'PYJSON'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for component in sys.argv[2].split("."):
    value = value[component]
if isinstance(value, bool) or not isinstance(value, (str, int, float)):
    raise SystemExit(1)
print(value)
PYJSON
}
fi

macho_dependencies() {
  local executable="$1"
  if [[ ! -f "$executable" ]]; then
    printf 'error: Mach-O executable is missing: %s\n' "$executable" >&2
    return 1
  fi
  # CEF role suffixes look like archive-member syntax to otool.
  /usr/bin/otool -L /dev/fd/9 9<"$executable"
}

macho_has_dependency() {
  local executable="$1"
  local expected_dependency="$2"
  local dependencies
  dependencies="$(macho_dependencies "$executable")" || return 1
  grep -Fq -- "$expected_dependency" <<<"$dependencies"
}

if ! declare -F codesign_signature_mode >/dev/null 2>&1; then
codesign_signature_mode() {
  local bundle="$1"
  local details
  if ! details="$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1)"; then
    printf '%s\n' 'invalid'
  elif printf '%s\n' "$details" | grep -Fq 'Signature=adhoc'; then
    printf '%s\n' 'adhoc'
  else
    printf '%s\n' 'fixed-identity'
  fi
}
fi

if ! declare -F codesign_leaf_authority >/dev/null 2>&1; then
codesign_leaf_authority() {
  local details
  details="$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1)"
  awk -F= '/^Authority=/ && !found {print substr($0, index($0, "=") + 1); found=1} END{exit(found ? 0 : 1)}' \
    <<<"$details"
}
fi

tatwo_cef_initialize_runtime_configuration() {
  local cache_root="$1"
  local pin_file="$2"
  local enable_cef="${3:-true}"

  CEF_PIN_FILE="$pin_file"
  CEF_VERSION=""
  CEF_CHROMIUM_VERSION=""
  CEF_PLATFORM=""
  CEF_CHANNEL=""
  CEF_ARCHIVE=""
  CEF_DOWNLOAD_URL=""
  CEF_OFFICIAL_INDEX_URL=""
  CEF_OFFICIAL_INDEX_SHA1=""
  CEF_ARCHIVE_SHA256=""
  CEF_ARCHIVE_SIZE=""
  CEF_LICENSE_SHA256=""
  CEF_ARCHIVE_PATH=""
  CEF_EXTRACTED_NAME=""
  CEF_RUNTIME_CACHE_DIR=""
  CEF_RUNTIME_ROOT=""
  CEF_RUNTIME_MANIFEST=""
  CEF_WRAPPER_LIBRARY=""
  CEF_WRAPPER_CACHE_KEY=""
  CEF_WRAPPER_SHA256_PATH=""
  CEF_INDEX_RECEIPT=""
  CEF_INDEX_RECEIPT_TEMP=""
  CEF_DOWNLOAD_TEMP=""
  CEF_INDEX_TEMP=""
  CEF_ARCHIVE_LIST=""
  CEF_EXTRACT_WORK=""
  CEF_WRAPPER_WORK=""
  CEF_PREPARED=false
  if [[ "$enable_cef" != "true" ]]; then
    return 0
  fi
  if [[ ! -f "$CEF_PIN_FILE" ]]; then
    printf 'error: CEF build requires the tracked CEF pin: %s\n' "$CEF_PIN_FILE" >&2
    return 1
  fi
  if [[ "$(uname -m)" != "arm64" ]]; then
    printf '%s\n' 'error: the pinned CEF runtime currently supports arm64 only' >&2
    return 1
  fi
  CEF_CACHE_ROOT="$cache_root"
  CEF_VERSION="$(json_string "$CEF_PIN_FILE" cefVersion)"
  CEF_CHROMIUM_VERSION="$(json_string "$CEF_PIN_FILE" chromiumVersion)"
  CEF_PLATFORM="$(json_string "$CEF_PIN_FILE" platform)"
  CEF_CHANNEL="$(json_string "$CEF_PIN_FILE" channel)"
  CEF_ARCHIVE="$(json_string "$CEF_PIN_FILE" archive)"
  CEF_DOWNLOAD_URL="$(json_string "$CEF_PIN_FILE" url)"
  CEF_OFFICIAL_INDEX_URL="$(json_string "$CEF_PIN_FILE" officialIndexURL)"
  CEF_OFFICIAL_INDEX_SHA1="$(json_string "$CEF_PIN_FILE" officialIndexSHA1)"
  CEF_ARCHIVE_SHA256="$(json_string "$CEF_PIN_FILE" sha256)"
  CEF_ARCHIVE_SIZE="$(json_scalar "$CEF_PIN_FILE" size)"
  CEF_LICENSE_SHA256="$(json_string "$CEF_PIN_FILE" licenseSHA256)"
  CEF_ARCHIVE_PATH="$CEF_CACHE_ROOT/vendor/cef/$CEF_ARCHIVE"
  CEF_EXTRACTED_NAME="${CEF_ARCHIVE%.tar.bz2}"
  CEF_RUNTIME_CACHE_DIR="$CEF_CACHE_ROOT/vendor/cef/runtime/$CEF_ARCHIVE_SHA256"
  CEF_RUNTIME_ROOT="$CEF_RUNTIME_CACHE_DIR/$CEF_EXTRACTED_NAME"
  CEF_RUNTIME_MANIFEST="$CEF_RUNTIME_CACHE_DIR/manifest.sha256"
  CEF_INDEX_RECEIPT="$CEF_CACHE_ROOT/vendor/cef/index-verified-$CEF_OFFICIAL_INDEX_SHA1.receipt"
}

remove_generated_cef_work_path() {
  local candidate="$1"
  if [[ -z "$candidate" || ! -e "$candidate" ]]; then
    return
  fi
  case "$candidate" in
    "$CEF_CACHE_ROOT/tmp/cef/extract-"*|"$CEF_CACHE_ROOT/build-cef/wrapper-"*)
      /bin/rm -rf -- "$candidate"
      ;;
    *)
      printf 'error: refusing to clean unexpected CEF work path: %s\n' \
        "$candidate" >&2
      return 1
      ;;
  esac
}

cleanup_cef_work() {
  local cleanup_status=0
  if ! remove_generated_cef_work_path "$CEF_EXTRACT_WORK"; then
    cleanup_status=1
  fi
  if ! remove_generated_cef_work_path "$CEF_WRAPPER_WORK"; then
    cleanup_status=1
  fi
  if [[ -n "$CEF_DOWNLOAD_TEMP" && -e "$CEF_DOWNLOAD_TEMP" ]]; then
    case "$CEF_DOWNLOAD_TEMP" in
      "$CEF_CACHE_ROOT/vendor/cef/"*.part-"$STAMP"-"$SHORT_TOKEN")
        /bin/rm -f -- "$CEF_DOWNLOAD_TEMP"
        ;;
      *)
        printf 'error: refusing to clean unexpected CEF download path: %s\n' \
          "$CEF_DOWNLOAD_TEMP" >&2
        cleanup_status=1
        ;;
    esac
  fi
  if [[ -n "$CEF_INDEX_TEMP" && -e "$CEF_INDEX_TEMP" ]]; then
    case "$CEF_INDEX_TEMP" in
      "$CEF_CACHE_ROOT/vendor/cef/"*.index-"$STAMP"-"$SHORT_TOKEN")
        /bin/rm -f -- "$CEF_INDEX_TEMP"
        ;;
      *)
        printf 'error: refusing to clean unexpected CEF index path: %s\n' \
          "$CEF_INDEX_TEMP" >&2
        cleanup_status=1
        ;;
    esac
  fi
  if [[ -n "$CEF_INDEX_RECEIPT_TEMP" && -e "$CEF_INDEX_RECEIPT_TEMP" ]]; then
    case "$CEF_INDEX_RECEIPT_TEMP" in
      "$CEF_CACHE_ROOT/vendor/cef/"*.receipt.tmp-"$STAMP"-"$SHORT_TOKEN")
        /bin/rm -f -- "$CEF_INDEX_RECEIPT_TEMP"
        ;;
      *)
        printf 'error: refusing to clean unexpected CEF index receipt temp: %s\n' \
          "$CEF_INDEX_RECEIPT_TEMP" >&2
        cleanup_status=1
        ;;
    esac
  fi
  if [[ -n "$CEF_ARCHIVE_LIST" && -e "$CEF_ARCHIVE_LIST" ]]; then
    case "$CEF_ARCHIVE_LIST" in
      "$CEF_CACHE_ROOT/tmp/cef/"*.entries-"$STAMP"-"$SHORT_TOKEN")
        /bin/rm -f -- "$CEF_ARCHIVE_LIST"
        ;;
      *)
        printf 'error: refusing to clean unexpected CEF archive list: %s\n' \
          "$CEF_ARCHIVE_LIST" >&2
        cleanup_status=1
        ;;
    esac
  fi
  CEF_DOWNLOAD_TEMP=""
  CEF_INDEX_TEMP=""
  CEF_INDEX_RECEIPT_TEMP=""
  CEF_ARCHIVE_LIST=""
  CEF_EXTRACT_WORK=""
  CEF_WRAPPER_WORK=""
  return "$cleanup_status"
}

validate_cef_runtime_root() {
  local candidate_root="$1"
  local actual_license_sha256
  if [[ ! -f "$candidate_root/LICENSE.txt" \
    || ! -d "$candidate_root/Release/Chromium Embedded Framework.framework" \
    || ! -f "$candidate_root/include/cef_app.h" ]]
  then
    printf '%s\n' 'error: extracted CEF runtime is incomplete' >&2
    return 1
  fi
  actual_license_sha256="$(
    shasum -a 256 "$candidate_root/LICENSE.txt" | awk '{print $1}'
  )"
  if [[ "$actual_license_sha256" != "$CEF_LICENSE_SHA256" ]]; then
    printf 'error: CEF license receipt mismatch: expected=%s actual=%s\n' \
      "$CEF_LICENSE_SHA256" "$actual_license_sha256" >&2
    return 1
  fi
}

validate_cef_distribution_pin() {
  /usr/bin/python3 - \
    "$CEF_VERSION" \
    "$CEF_CHROMIUM_VERSION" \
    "$CEF_PLATFORM" \
    "$CEF_CHANNEL" \
    "$CEF_ARCHIVE" \
    "$CEF_DOWNLOAD_URL" \
    "$CEF_OFFICIAL_INDEX_URL" \
    "$CEF_OFFICIAL_INDEX_SHA1" <<'PY'
import re
import sys
import urllib.parse

(
    cef_version,
    chromium_version,
    platform,
    channel,
    archive,
    download_url,
    index_url,
    official_sha1,
) = sys.argv[1:]
allowed_hosts = {"cef-builds.spotifycdn.com"}
expected_archive = f"cef_binary_{cef_version}_{platform}_minimal.tar.bz2"
if (
    platform != "macosarm64"
    or channel != "stable"
    or archive != expected_archive
    or chromium_version not in cef_version
):
    raise SystemExit("CEF pin version/platform/archive mismatch")
for raw_url, expected_path in (
    (download_url, "/" + archive),
    (index_url, "/index.json"),
):
    parsed = urllib.parse.urlsplit(raw_url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in allowed_hosts
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
        or parsed.path != expected_path
        or parsed.query
        or parsed.fragment
    ):
        raise SystemExit(f"untrusted CEF distribution URL: {raw_url}")
if not re.fullmatch(r"[0-9a-f]{40}", official_sha1):
    raise SystemExit("invalid official CEF archive SHA1")
PY
}

validate_cef_official_index() {
  local index_path="$1"
  /usr/bin/python3 - \
    "$index_path" \
    "$CEF_ARCHIVE" \
    "$CEF_OFFICIAL_INDEX_SHA1" \
    "$CEF_ARCHIVE_SIZE" <<'PY'
import json
import sys

index_path, archive, expected_sha1, expected_size = sys.argv[1:]
document = json.load(open(index_path, encoding="utf-8"))

def dictionaries(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from dictionaries(child)
    elif isinstance(value, list):
        for child in value:
            yield from dictionaries(child)

matches = []
for item in dictionaries(document):
    name = item.get("name") or item.get("file") or item.get("archive")
    sha1 = item.get("sha1") or item.get("sha")
    if name == archive and sha1 == expected_sha1:
        size = item.get("size")
        if size is None or str(size) == expected_size:
            matches.append(item)
if len(matches) != 1:
    raise SystemExit(
        f"official CEF index binding mismatch: archive={archive} matches={len(matches)}"
    )
PY
}

cef_index_receipt_matches_pin() {
  local receipt_path="$1"
  /usr/bin/python3 - \
    "$receipt_path" \
    "$CEF_ARCHIVE" \
    "$CEF_OFFICIAL_INDEX_URL" \
    "$CEF_OFFICIAL_INDEX_SHA1" \
    "$CEF_ARCHIVE_SHA256" <<'PY'
import json
import re
import sys

(
    receipt_path,
    archive,
    index_url,
    official_sha1,
    archive_sha256,
) = sys.argv[1:]
try:
    with open(receipt_path, encoding="utf-8") as handle:
        receipt = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
expected = {
    "schema": "TatwoCEFOfficialIndexReceiptV1",
    "archive": archive,
    "officialIndexURL": index_url,
    "officialIndexSHA1": official_sha1,
    "archiveSHA256": archive_sha256,
}
if any(receipt.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}", receipt.get("indexSHA256", "")):
    raise SystemExit(1)
if not isinstance(receipt.get("verifiedAt"), str) or not receipt["verifiedAt"]:
    raise SystemExit(1)
PY
}

write_cef_index_receipt() {
  local index_path="$1"
  local index_sha256
  index_sha256="$(shasum -a 256 "$index_path" | awk '{print $1}')"
  CEF_INDEX_RECEIPT_TEMP="$CEF_INDEX_RECEIPT.tmp-$STAMP-$SHORT_TOKEN"
  /usr/bin/python3 - \
    "$CEF_INDEX_RECEIPT_TEMP" \
    "$STAMP" \
    "$CEF_ARCHIVE" \
    "$CEF_OFFICIAL_INDEX_URL" \
    "$CEF_OFFICIAL_INDEX_SHA1" \
    "$CEF_ARCHIVE_SHA256" \
    "$index_sha256" <<'PY'
import json
import os
import sys

(
    receipt_path,
    verified_at,
    archive,
    index_url,
    official_sha1,
    archive_sha256,
    index_sha256,
) = sys.argv[1:]
receipt = {
    "schema": "TatwoCEFOfficialIndexReceiptV1",
    "verifiedAt": verified_at,
    "archive": archive,
    "officialIndexURL": index_url,
    "officialIndexSHA1": official_sha1,
    "archiveSHA256": archive_sha256,
    "indexSHA256": index_sha256,
}
with open(receipt_path, "x", encoding="utf-8") as handle:
    json.dump(receipt, handle, ensure_ascii=False, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
  mv "$CEF_INDEX_RECEIPT_TEMP" "$CEF_INDEX_RECEIPT"
  CEF_INDEX_RECEIPT_TEMP=""
}

validate_cef_archive_entries() {
  CEF_ARCHIVE_LIST="$CEF_CACHE_ROOT/tmp/cef/$CEF_ARCHIVE.entries-$STAMP-$SHORT_TOKEN"
  tar -tjf "$CEF_ARCHIVE_PATH" >"$CEF_ARCHIVE_LIST"
  /usr/bin/python3 - \
    "$CEF_ARCHIVE_PATH" \
    "$CEF_ARCHIVE_LIST" \
    "$CEF_EXTRACTED_NAME" <<'PY'
import pathlib
import posixpath
import sys
import tarfile

archive_path, list_path, expected_root = sys.argv[1:]
listed = open(list_path, encoding="utf-8").read().splitlines()
if not listed:
    raise SystemExit("CEF archive entry list is empty")

def checked_name(raw):
    if not raw or raw.startswith("/"):
        raise SystemExit(f"unsafe absolute/empty CEF archive entry: {raw!r}")
    path = pathlib.PurePosixPath(raw)
    if ".." in path.parts or "." in path.parts:
        raise SystemExit(f"unsafe traversal CEF archive entry: {raw}")
    if not path.parts or path.parts[0] != expected_root:
        raise SystemExit(f"CEF archive entry escapes expected root: {raw}")
    return path

for raw in listed:
    checked_name(raw.rstrip("/"))

with tarfile.open(archive_path, mode="r:bz2") as archive:
    members = archive.getmembers()
    if len(members) != len(listed):
        raise SystemExit("CEF archive list/member count mismatch")
    for member in members:
        member_path = checked_name(member.name.rstrip("/"))
        if member.ischr() or member.isblk() or member.isfifo():
            raise SystemExit(f"unsafe special CEF archive entry: {member.name}")
        if member.issym():
            if not member.linkname or member.linkname.startswith("/"):
                raise SystemExit(f"unsafe CEF symlink target: {member.name}")
            resolved = pathlib.PurePosixPath(
                posixpath.normpath(
                    posixpath.join(str(member_path.parent), member.linkname)
                )
            )
            if not resolved.parts or resolved.parts[0] != expected_root:
                raise SystemExit(f"escaping CEF symlink target: {member.name}")
        elif member.islnk():
            target = checked_name(member.linkname)
            if not target.parts or target.parts[0] != expected_root:
                raise SystemExit(f"escaping CEF hardlink target: {member.name}")
PY
}

validate_extracted_cef_tree() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
prefix = root + os.sep
for current, directories, files in os.walk(root, followlinks=False):
    for leaf in directories + files:
        path = os.path.join(current, leaf)
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode):
            resolved = os.path.realpath(path)
            if resolved != root and not resolved.startswith(prefix):
                raise SystemExit(f"extracted CEF symlink escapes root: {path}")
        elif not (
            stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISREG(metadata.st_mode)
        ):
            raise SystemExit(f"unsupported extracted CEF entry type: {path}")
PY
}

process_cef_tree_manifest() {
  local mode="$1"
  local runtime_root="$2"
  local manifest_path="$3"
  /usr/bin/python3 - "$mode" "$runtime_root" "$manifest_path" <<'PY'
import hashlib
import json
import os
import shlex
import stat
import sys

mode, root, manifest_path = sys.argv[1:]

def fail():
    raise SystemExit(
        "cached CEF runtime manifest mismatch; "
        f"move the cache to Trash (`trash -- "
        f"{shlex.quote(os.path.dirname(root))}`) "
        "and rebuild"
    )

def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def collect(directory):
    records = []
    try:
        entries = sorted(os.scandir(directory), key=lambda item: item.name)
    except OSError:
        fail()
    for entry in entries:
        path = entry.path
        relative = os.path.relpath(path, root)
        try:
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path).encode(
                    "utf-8",
                    errors="surrogateescape",
                )
                records.append({
                    "path": relative,
                    "type": "symlink",
                    "size": len(target),
                    "sha256": hashlib.sha256(target).hexdigest(),
                })
            elif stat.S_ISDIR(metadata.st_mode):
                records.append({
                    "path": relative,
                    "type": "directory",
                    "size": 0,
                    "sha256": hashlib.sha256(b"").hexdigest(),
                })
                records.extend(collect(path))
            elif stat.S_ISREG(metadata.st_mode):
                records.append({
                    "path": relative,
                    "type": "file",
                    "size": metadata.st_size,
                    "sha256": digest_file(path),
                })
            else:
                fail()
        except OSError:
            fail()
    return records

if mode == "write":
    try:
        with open(manifest_path, "x", encoding="utf-8") as handle:
            for record in collect(root):
                handle.write(json.dumps(
                    record,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ))
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except OSError:
        fail()
elif mode == "validate":
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            expected = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        fail()
    if expected != collect(root):
        fail()
else:
    raise SystemExit("invalid CEF tree manifest mode")
PY
}

write_cef_tree_manifest() {
  process_cef_tree_manifest write "$1" "$2"
}

validate_cef_tree_manifest() {
  process_cef_tree_manifest validate "$1" "$2"
}

CEF_PREPARED=false
prepare_cef_runtime() {
  local vendor_root="$CEF_CACHE_ROOT/vendor/cef"
  local runtime_cache_parent="$vendor_root/runtime"
  local extracted_candidate
  local manifest_candidate
  local wrapper_cache_dir
  local wrapper_objects
  local wrapper_source_list
  local wrapper_flags
  local wrapper_expected_sha256
  local wrapper_actual_sha256
  local wrapper_built_sha256
  local actual_sha256
  local actual_size

  for cache_component in \
    "$vendor_root" \
    "$runtime_cache_parent" \
    "$CEF_CACHE_ROOT/build-cef"
  do
    if [[ -L "$cache_component" ]]; then
      printf '%s\n' \
        'error: CEF cache authority contains a symbolic link' >&2
      exit 1
    fi
  done
  mkdir -p \
    "$vendor_root" \
    "$runtime_cache_parent" \
    "$CEF_CACHE_ROOT/tmp/cef" \
    "$CEF_CACHE_ROOT/build-cef" \
    "$CEF_CACHE_ROOT/runtime/browser-profiles" \
    "$CEF_CACHE_ROOT/runtime/cef-root" \
    "$CEF_CACHE_ROOT/runtime/cef-logs"

  validate_cef_distribution_pin
  if [[ "$REFRESH_CEF_INDEX" != "true" \
    && -f "$CEF_INDEX_RECEIPT" ]] \
    && cef_index_receipt_matches_pin "$CEF_INDEX_RECEIPT"
  then
    printf '%s\n' 'CEF_OFFICIAL_INDEX=receipt-reused'
  else
    CEF_INDEX_TEMP="$vendor_root/$CEF_ARCHIVE.index-$STAMP-$SHORT_TOKEN"
    curl --fail --proto '=https' --tlsv1.2 --max-redirs 0 \
      --retry 3 --connect-timeout 20 --max-time 120 \
      --output "$CEF_INDEX_TEMP" "$CEF_OFFICIAL_INDEX_URL"
    validate_cef_official_index "$CEF_INDEX_TEMP"
    write_cef_index_receipt "$CEF_INDEX_TEMP"
    printf '%s\n' 'CEF_OFFICIAL_INDEX=verified'
  fi

  if [[ ! -f "$CEF_ARCHIVE_PATH" ]]; then
    CEF_DOWNLOAD_TEMP="$CEF_ARCHIVE_PATH.part-$STAMP-$SHORT_TOKEN"
    curl --fail --proto '=https' --tlsv1.2 --max-redirs 0 \
      --retry 3 --connect-timeout 20 --max-time 900 \
      --output "$CEF_DOWNLOAD_TEMP" "$CEF_DOWNLOAD_URL"
    actual_sha256="$(shasum -a 256 "$CEF_DOWNLOAD_TEMP" | awk '{print $1}')"
    actual_size="$(stat -f %z "$CEF_DOWNLOAD_TEMP")"
    if [[ "$actual_sha256" != "$CEF_ARCHIVE_SHA256" \
      || "$actual_size" != "$CEF_ARCHIVE_SIZE" ]]
    then
      printf 'error: downloaded CEF archive verification failed: sha256=%s size=%s\n' \
        "$actual_sha256" "$actual_size" >&2
      exit 1
    fi
    mv "$CEF_DOWNLOAD_TEMP" "$CEF_ARCHIVE_PATH"
    CEF_DOWNLOAD_TEMP=""
  fi

  actual_sha256="$(shasum -a 256 "$CEF_ARCHIVE_PATH" | awk '{print $1}')"
  actual_size="$(stat -f %z "$CEF_ARCHIVE_PATH")"
  if [[ "$actual_sha256" != "$CEF_ARCHIVE_SHA256" \
    || "$actual_size" != "$CEF_ARCHIVE_SIZE" ]]
  then
    printf 'error: cached CEF archive verification failed closed: sha256=%s size=%s\n' \
      "$actual_sha256" "$actual_size" >&2
    exit 1
  fi

  printf -v cef_runtime_cache_shell_quoted '%q' "$CEF_RUNTIME_CACHE_DIR"
  if [[ -L "$CEF_RUNTIME_CACHE_DIR" \
    || -L "$CEF_RUNTIME_ROOT" \
    || -L "$CEF_RUNTIME_MANIFEST" ]]
  then
    printf '%s\n' \
      "error: cached CEF runtime path is a symbolic link; move the cache to Trash (\`trash -- $cef_runtime_cache_shell_quoted\`) and rebuild" \
      >&2
    exit 1
  fi
  if [[ -d "$CEF_RUNTIME_ROOT" && -f "$CEF_RUNTIME_MANIFEST" ]]; then
    validate_extracted_cef_tree "$CEF_RUNTIME_ROOT"
    validate_cef_tree_manifest \
      "$CEF_RUNTIME_ROOT" \
      "$CEF_RUNTIME_MANIFEST"
    validate_cef_runtime_root "$CEF_RUNTIME_ROOT"
    printf '%s\n' 'CEF_RUNTIME_CACHE=verified-reuse'
  else
    if [[ -e "$CEF_RUNTIME_CACHE_DIR" \
      || -L "$CEF_RUNTIME_CACHE_DIR" ]]
    then
      printf '%s\n' \
        "error: cached CEF runtime is incomplete; move the cache to Trash (\`trash -- $cef_runtime_cache_shell_quoted\`) and rebuild" \
        >&2
      exit 1
    fi
    validate_cef_archive_entries
    CEF_EXTRACT_WORK="$CEF_CACHE_ROOT/tmp/cef/extract-$STAMP-$SHORT_TOKEN"
    mkdir -p "$CEF_EXTRACT_WORK"
    TMPDIR="$CEF_CACHE_ROOT/tmp/cef" \
      tar -xjf "$CEF_ARCHIVE_PATH" -C "$CEF_EXTRACT_WORK"
    actual_sha256="$(shasum -a 256 "$CEF_ARCHIVE_PATH" | awk '{print $1}')"
    actual_size="$(stat -f %z "$CEF_ARCHIVE_PATH")"
    if [[ "$actual_sha256" != "$CEF_ARCHIVE_SHA256" \
      || "$actual_size" != "$CEF_ARCHIVE_SIZE" ]]
    then
      printf '%s\n' \
        'error: CEF archive changed during validation/extraction' >&2
      exit 1
    fi
    extracted_candidate="$CEF_EXTRACT_WORK/$CEF_EXTRACTED_NAME"
    if [[ ! -d "$extracted_candidate" || -L "$extracted_candidate" ]]; then
      printf '%s\n' \
        'error: CEF archive did not contain the expected runtime root' >&2
      exit 1
    fi
    validate_extracted_cef_tree "$extracted_candidate"
    validate_cef_runtime_root "$extracted_candidate"
    manifest_candidate="$CEF_EXTRACT_WORK/manifest.sha256"
    write_cef_tree_manifest "$extracted_candidate" "$manifest_candidate"
    validate_cef_tree_manifest "$extracted_candidate" "$manifest_candidate"
    mkdir "$CEF_RUNTIME_CACHE_DIR"
    mv "$extracted_candidate" "$CEF_RUNTIME_ROOT"
    mv "$manifest_candidate" "$CEF_RUNTIME_MANIFEST"
    printf '%s\n' 'CEF_RUNTIME_CACHE=created-and-verified'
  fi

  wrapper_flags='arm64|min-macos=14.0|O2|cxx20|no-exceptions|no-rtti|hidden'
  CEF_WRAPPER_CACHE_KEY="$(
    {
      printf 'archive-sha256=%s\nflags=%s\n' \
        "$CEF_ARCHIVE_SHA256" "$wrapper_flags"
      xcrun --find clang++
      xcrun clang++ --version
      xcrun --find libtool
      xcrun --show-sdk-path
      xcrun --show-sdk-version
    } | shasum -a 256 | awk '{print $1}'
  )"
  wrapper_cache_dir="$CEF_CACHE_ROOT/build-cef/$CEF_ARCHIVE_SHA256/$CEF_WRAPPER_CACHE_KEY"
  if [[ -L "$CEF_CACHE_ROOT/build-cef/$CEF_ARCHIVE_SHA256" \
    || -L "$wrapper_cache_dir" ]]
  then
    printf '%s\n' 'error: CEF wrapper cache path is a symbolic link' >&2
    exit 1
  fi
  CEF_WRAPPER_LIBRARY="$wrapper_cache_dir/libcef_dll_wrapper.a"
  CEF_WRAPPER_SHA256_PATH="$CEF_WRAPPER_LIBRARY.sha256"
  wrapper_expected_sha256=""
  wrapper_actual_sha256=""
  if [[ -f "$CEF_WRAPPER_LIBRARY" \
    && ! -L "$CEF_WRAPPER_LIBRARY" \
    && -f "$CEF_WRAPPER_SHA256_PATH" \
    && ! -L "$CEF_WRAPPER_SHA256_PATH" ]]
  then
    wrapper_expected_sha256="$(tr -d '[:space:]' < "$CEF_WRAPPER_SHA256_PATH")"
    wrapper_actual_sha256="$(
      shasum -a 256 "$CEF_WRAPPER_LIBRARY" | awk '{print $1}'
    )"
  fi
  if [[ "$wrapper_expected_sha256" =~ ^[0-9a-f]{64}$ \
    && "$wrapper_actual_sha256" == "$wrapper_expected_sha256" ]]
  then
    printf '%s\n' 'CEF_WRAPPER_CACHE=verified-reuse'
  else
    CEF_WRAPPER_WORK="$CEF_CACHE_ROOT/build-cef/wrapper-$CEF_ARCHIVE_SHA256-$CEF_WRAPPER_CACHE_KEY-$STAMP-$SHORT_TOKEN"
    wrapper_objects="$CEF_WRAPPER_WORK/objects"
    wrapper_source_list="$CEF_WRAPPER_WORK/sources.txt"
    mkdir -p "$wrapper_objects"
    find "$CEF_RUNTIME_ROOT/libcef_dll" \
      -type f \
      \( -name '*.cc' -o -name '*.mm' \) \
      ! -name '*_win.cc' \
      -print | LC_ALL=C sort >"$wrapper_source_list"
    if [[ ! -s "$wrapper_source_list" ]]; then
      printf '%s\n' 'error: CEF wrapper source list is empty' >&2
      exit 1
    fi
    xargs -P 2 -S 4096 -I '{}' /bin/bash -c '
      set -euo pipefail
      source_path="$1"
      cef_root="$2"
      objects_root="$3"
      relative="${source_path#"$cef_root"/}"
      object_key="$(printf "%s" "$relative" | shasum -a 256 | cut -d " " -f 1)"
      xcrun clang++ \
        -arch arm64 \
        -mmacosx-version-min=14.0 \
        -O2 \
        -I"$cef_root" \
        -DWRAPPING_CEF_SHARED \
        -DUSING_CEF_SHARED \
        -fno-exceptions \
        -fno-rtti \
        -fno-threadsafe-statics \
        -fobjc-call-cxx-cdtors \
        -fvisibility=hidden \
        -fvisibility-inlines-hidden \
        -std=c++20 \
        -Wno-narrowing \
        -Wno-undefined-var-template \
        -Wno-deprecated-declarations \
        -c "$source_path" \
        -o "$objects_root/$object_key.o"
    ' _ '{}' "$CEF_RUNTIME_ROOT" "$wrapper_objects" \
      <"$wrapper_source_list"
    xcrun libtool -static \
      -o "$CEF_WRAPPER_WORK/libcef_dll_wrapper.a" \
      "$wrapper_objects"/*.o
    wrapper_built_sha256="$(
      shasum -a 256 "$CEF_WRAPPER_WORK/libcef_dll_wrapper.a" \
        | awk '{print $1}'
    )"
    printf '%s\n' "$wrapper_built_sha256" \
      >"$CEF_WRAPPER_WORK/libcef_dll_wrapper.a.sha256"
    mkdir -p "$wrapper_cache_dir"
    mv "$CEF_WRAPPER_WORK/libcef_dll_wrapper.a" "$CEF_WRAPPER_LIBRARY"
    mv "$CEF_WRAPPER_WORK/libcef_dll_wrapper.a.sha256" \
      "$CEF_WRAPPER_SHA256_PATH"
    printf '%s\n' 'CEF_WRAPPER_CACHE=rebuilt'
  fi

  export TATWO_CEF_ROOT="$CEF_RUNTIME_ROOT"
  export TATWO_CEF_WRAPPER_LIBRARY="$CEF_WRAPPER_LIBRARY"
  export TATWO_ENABLE_CEF=1
  if [[ "${TATWO_ENABLE_CEF:-0}" != "1" \
    || ! -f "$TATWO_CEF_WRAPPER_LIBRARY" \
    || ! -f "$TATWO_CEF_ROOT/include/cef_app.h" ]]
  then
    printf '%s\n' \
      'error: --enable-cef was requested but the verified CEF build environment is inactive' \
      >&2
    exit 1
  fi
  CEF_PREPARED=true
  printf 'CEF_RUNTIME=enabled version=%s chromium=%s sha256=%s wrapperKey=%s\n' \
    "$CEF_VERSION" \
    "$CEF_CHROMIUM_VERSION" \
    "$CEF_ARCHIVE_SHA256" \
    "$CEF_WRAPPER_CACHE_KEY"
}


tatwo_cef_stage_app_artifacts() {
  local app_bundle="$1"
  local main_executable_name="$2"
  local build_bin_path="$3"
  local cef_runtime_root="$4"
  local main_bundle_name="$5"
  local bundle_id="$6"
  local short_version="$7"
  local build_version="$8"
  local minimum_system_version="$9"
  local removable_description="${10}"
  local network_description="${11}"
  local contents="$app_bundle/Contents"
  local frameworks="$contents/Frameworks"
  local framework_source="$cef_runtime_root/Release/Chromium Embedded Framework.framework"
  local framework_destination="$frameworks/Chromium Embedded Framework.framework"
  local helper_base_name="$main_bundle_name Helper"
  local helper_name_suffixes=("" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)")
  local helper_bundle_id_suffixes=("" ".alerts" ".gpu" ".plugin" ".renderer")
  local main_framework_link='@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework'
  local helper_build_framework_link="$main_framework_link"
  local helper_bundle_framework_link='@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework'
  local helper_index helper_name helper_app helper_contents helper_macos helper_executable helper_bundle_id

  [[ -d "$framework_source" ]] || {
    printf 'error: CEF framework source is missing: %s\n' "$framework_source" >&2
    return 1
  }
  [[ -x "$build_bin_path/TatwoCEFHelper" ]] || {
    printf 'error: CEF helper build product is missing: %s\n' "$build_bin_path/TatwoCEFHelper" >&2
    return 1
  }
  mkdir -p "$frameworks"
  /usr/bin/ditto "$framework_source" "$framework_destination"
  for helper_index in "${!helper_name_suffixes[@]}"; do
    helper_name="$helper_base_name${helper_name_suffixes[$helper_index]}"
    helper_app="$frameworks/$helper_name.app"
    helper_contents="$helper_app/Contents"
    helper_macos="$helper_contents/MacOS"
    helper_executable="$helper_macos/$helper_name"
    helper_bundle_id="$bundle_id.cef-helper${helper_bundle_id_suffixes[$helper_index]}"
    mkdir -p "$helper_macos"
    cp "$build_bin_path/TatwoCEFHelper" "$helper_executable"
    chmod +x "$helper_executable"
    if macho_has_dependency "$helper_executable" "$helper_build_framework_link"; then
      /usr/bin/install_name_tool -change \
        "$helper_build_framework_link" \
        "$helper_bundle_framework_link" \
        "$helper_executable"
    fi
    cat >"$helper_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$helper_name</string>
  <key>CFBundleIdentifier</key><string>$helper_bundle_id</string>
  <key>CFBundleName</key><string>$helper_name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleVersion</key><string>$build_version</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>$minimum_system_version</string>
  <key>NSRemovableVolumesUsageDescription</key><string>$removable_description</string>
  <key>NSNetworkVolumesUsageDescription</key><string>$network_description</string>
</dict></plist>
PLIST
    printf 'APPL????' >"$helper_contents/PkgInfo"
  done
  if ! macho_has_dependency \
    "$contents/MacOS/$main_executable_name" "$main_framework_link"
  then
    printf 'error: CEF main binary has the wrong Chromium framework dependency: %s\n' \
      "$contents/MacOS/$main_executable_name" >&2
    return 1
  fi
  printf 'CEF_ARTIFACTS_STAGED=%s\n' "$app_bundle"
}

tatwo_cef_sign_nested_artifacts() {
  local app_bundle="$1"
  local signing_identity="$2"
  local signing_mode="${3:-adhoc}"
  local contents="$app_bundle/Contents"
  local framework="$contents/Frameworks/Chromium Embedded Framework.framework"
  local sign_args=(--force --sign "$signing_identity")
  local helper_app
  local nested_code
  if [[ "$signing_mode" == "secure" ]]; then
    sign_args+=(--options runtime --timestamp)
  else
    sign_args+=(--timestamp=none)
  fi
  if [[ "$signing_mode" != "adhoc" && "$signing_mode" != "ad-hoc" ]]; then
    while IFS= read -r -d '' nested_code; do
      if /usr/bin/file -b "$nested_code" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign "${sign_args[@]}" "$nested_code"
      fi
    done < <(
      find "$framework" -type f \
        \( -perm -111 -o -name '*.dylib' \) -print0 \
        | LC_ALL=C sort -z
    )
  fi
  /usr/bin/codesign --deep "${sign_args[@]}" "$framework"
  while IFS= read -r -d '' helper_app; do
    /usr/bin/codesign "${sign_args[@]}" "$helper_app"
  done < <(find "$contents/Frameworks" -maxdepth 1 -type d -name '* Helper*.app' -print0 | LC_ALL=C sort -z)
  printf 'CEF_NESTED_SIGNATURES=passed mode=%s\n' "$signing_mode"
}

assert_plist_value_equals() {
  local plist_path="$1"
  local plist_key="$2"
  local expected_value="$3"
  local actual_value
  actual_value="$(plist_string "$plist_path" "$plist_key")"
  if [[ "$actual_value" != "$expected_value" ]]; then
    printf 'error: candidate plist changed protected value %s: expected=%s actual=%s\n' \
      "$plist_key" "$expected_value" "$actual_value" >&2
    exit 1
  fi
}

assert_bundle_uses_signing_identity() {
  local bundle="$1"
  local expected_mode="${2:-${SIGNING_MODE:-fixed-identity}}"
  local expected_identity="${3:-${SIGNING_IDENTITY_NAME:-}}"
  local mode
  local authority=""
  mode="$(codesign_signature_mode "$bundle")"
  if [[ "$mode" == "fixed-identity" ]]; then
    authority="$(codesign_leaf_authority "$bundle" || true)"
  fi
  case "$expected_mode" in
    ad-hoc|adhoc)
      if [[ "$mode" == "adhoc" ]]; then
        return
      fi
      ;;
    developer-id|apple-development|fixed-identity)
      if [[ "$mode" == "fixed-identity" \
        && -n "$expected_identity" \
        && "$authority" == "$expected_identity" ]]
      then
        return
      fi
      ;;
    *)
      printf 'error: unsupported expected signing mode: %s\n' \
        "$expected_mode" >&2
      exit 1
      ;;
  esac
  if [[ "$mode" != "$expected_mode" || "$authority" != "$expected_identity" ]]; then
    printf 'error: bundle signing identity mismatch: mode=%s authority=%s expected=%s\n' \
      "$mode" "$authority" "${expected_identity:--} ($expected_mode)" >&2
    exit 1
  fi
}

assert_macho_contains_architecture() {
  local executable="$1"
  local expected_architecture="$2"
  local architectures
  if [[ ! -x "$executable" ]]; then
    printf 'error: required executable is missing or not executable: %s\n' \
      "$executable" >&2
    exit 1
  fi
  if ! architectures="$(lipo -archs "$executable" 2>/dev/null)"; then
    printf 'error: unable to inspect executable architectures: %s\n' \
      "$executable" >&2
    exit 1
  fi
  if ! grep -Eq "(^|[[:space:]])${expected_architecture}($|[[:space:]])" \
    <<<"$architectures"
  then
    printf 'error: executable is missing required architecture %s: %s (%s)\n' \
      "$expected_architecture" "$executable" "$architectures" >&2
    exit 1
  fi
}

verify_cef_app_artifacts() {
  local bundle="$1"
  local expected_main_executable="${2:-${STAGING_EXECUTABLE:-${PRODUCT_NAME:-}}}"
  local expected_bundle_id="${3:-${BUNDLE_ID:-${TATWO_MAIN_APP_BUNDLE_ID:-}}}"
  local expected_signing_mode="${4:-${SIGNING_MODE:-fixed-identity}}"
  local expected_signing_identity="${5:-${SIGNING_IDENTITY_NAME:-}}"
  local expected_removable_description="${6:-${REMOVABLE_VOLUME_USAGE_DESCRIPTION:-}}"
  local expected_network_description="${7:-${NETWORK_VOLUME_USAGE_DESCRIPTION:-}}"
  local contents="$bundle/Contents"
  local main_executable="$contents/MacOS/$expected_main_executable"
  local main_bundle_name
  local framework="$contents/Frameworks/Chromium Embedded Framework.framework"
  local framework_info="$framework/Resources/Info.plist"
  local framework_resources="$framework/Resources"
  local framework_executable_name
  local framework_executable
  local helper_base_name
  local helper_name_suffixes=(
    ""
    " (Alerts)"
    " (GPU)"
    " (Plugin)"
    " (Renderer)"
  )
  local helper_bundle_id_suffixes=(
    ""
    ".alerts"
    ".gpu"
    ".plugin"
    ".renderer"
  )
  local helper_index
  local helper_name
  local helper_app
  local helper_info
  local helper_executable
  local helper_bundle_id
  local main_framework_link='@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework'
  local helper_framework_link='@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework'

  if [[ "$ENABLE_CEF" != "true" ]]; then
    return
  fi
  if [[ ! -f "$framework_info" || ! -d "$framework_resources" ]]; then
    printf 'error: CEF framework metadata or resources are missing: %s\n' \
      "$framework" >&2
    exit 1
  fi
  framework_executable_name="$(
    plist_string "$framework_info" CFBundleExecutable
  )"
  framework_executable="$framework/$framework_executable_name"
  if [[ ! -x "$framework_executable" ]]; then
    printf 'error: CEF framework executable is missing: %s\n' \
      "$framework_executable" >&2
    exit 1
  fi
  if [[ ! -f "$framework_resources/icudtl.dat" \
    || ! -f "$framework_resources/resources.pak" \
    || ! -d "$framework_resources/en.lproj" ]]
  then
    printf 'error: CEF framework resources are incomplete: %s\n' \
      "$framework_resources" >&2
    exit 1
  fi
  assert_plist_value_equals \
    "$contents/Info.plist" CFBundleIdentifier "$expected_bundle_id"
  assert_plist_value_equals \
    "$contents/Info.plist" TatwoBrowserEngine chromium-cef
  assert_plist_value_equals \
    "$contents/Info.plist" NSPrincipalClass TatwoCEFApplication
  main_bundle_name="$(plist_string "$contents/Info.plist" CFBundleName)"
  if [[ -z "$main_bundle_name" ]]; then
    printf 'error: CEF main bundle name is missing: %s\n' \
      "$contents/Info.plist" >&2
    exit 1
  fi
  helper_base_name="$main_bundle_name Helper"

  if ! macho_has_dependency "$main_executable" "$main_framework_link"; then
    printf 'error: CEF main executable lost its app-relative framework dependency: %s\n' \
      "$main_executable" >&2
    exit 1
  fi
  assert_macho_contains_architecture "$main_executable" arm64
  assert_macho_contains_architecture "$framework_executable" arm64
  for helper_index in "${!helper_name_suffixes[@]}"; do
    helper_name="$helper_base_name${helper_name_suffixes[$helper_index]}"
    helper_app="$contents/Frameworks/$helper_name.app"
    helper_info="$helper_app/Contents/Info.plist"
    helper_executable="$helper_app/Contents/MacOS/$helper_name"
    helper_bundle_id="$expected_bundle_id.cef-helper${helper_bundle_id_suffixes[$helper_index]}"
    if [[ ! -f "$helper_info" ]]; then
      printf 'error: required CEF helper variant is missing: %s\n' \
        "$helper_app" >&2
      exit 1
    fi
    assert_plist_value_equals \
      "$helper_info" CFBundleExecutable "$helper_name"
    assert_plist_value_equals \
      "$helper_info" CFBundleIdentifier "$helper_bundle_id"
    assert_plist_value_equals \
      "$helper_info" \
      NSRemovableVolumesUsageDescription \
      "$expected_removable_description"
    assert_plist_value_equals \
      "$helper_info" \
      NSNetworkVolumesUsageDescription \
      "$expected_network_description"
    if [[ ! -x "$helper_executable" ]]; then
      printf 'error: required CEF helper executable is missing: %s\n' \
        "$helper_executable" >&2
      exit 1
    fi
    if ! macho_has_dependency \
      "$helper_executable" \
      "$helper_framework_link"
    then
      printf 'error: CEF helper variant cannot resolve the app-bundled Chromium framework: %s\n' \
        "$helper_executable" >&2
      exit 1
    fi
    assert_macho_contains_architecture "$helper_executable" arm64
    codesign --verify --strict "$helper_app"
    assert_bundle_uses_signing_identity \
      "$helper_app" "$expected_signing_mode" "$expected_signing_identity"
  done
  codesign --verify --strict "$framework"
  assert_bundle_uses_signing_identity \
    "$framework" "$expected_signing_mode" "$expected_signing_identity"
  printf 'CEF_ARTIFACTS_VERIFIED=%s\n' "$bundle"
}
