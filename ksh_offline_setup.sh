#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly PACKAGE_NAME="ksh"
readonly TARGET_RHEL_MAJOR="9"
readonly TARGET_RHEL_VERSION="9.6"
readonly BUNDLE_PREFIX="ksh-offline-rhel${TARGET_RHEL_VERSION}"
readonly LOG_TS_FORMAT="+%Y-%m-%d %H:%M:%S%z"

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date "${LOG_TS_FORMAT}")" "${level}" "$*" >&2
}

info() {
  log "INFO" "$@"
}

warn() {
  log "WARN" "$@"
}

error() {
  log "ERROR" "$@"
}

die() {
  error "$@"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]:-${LINENO}}"
  error "Unexpected failure at line ${line_no}: ${BASH_COMMAND} (exit=${exit_code})"
  exit "${exit_code}"
}
trap on_error ERR

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} prepare [--work-dir DIR] [--output-dir DIR]
  ${SCRIPT_NAME} install [--rpm-dir DIR]
  ${SCRIPT_NAME} verify
  ${SCRIPT_NAME} --help

Modes:
  prepare
    Run on an online RHEL 9.6 host with matching architecture.
    Downloads ksh and dependency RPMs with dnf download --resolve,
    writes manifests and SHA256SUMS, and creates:
      ksh-offline-rhel9.6-<arch>.tar.gz

  install
    Run as root on the offline RHEL 9.x host after extracting the bundle.
    Verifies RPM files and SHA256SUMS, then installs with rpm -Uvh.
    It never uses --nodeps or --force.

  verify
    Verifies the ksh RPM, executable path, version output, and a small ksh script.

Options:
  --work-dir DIR
    Temporary work directory for prepare. Default: ./ksh-offline-work

  --output-dir DIR
    Directory where the tar.gz bundle is written. Default: current directory

  --rpm-dir DIR
    Extracted bundle directory or RPM directory for install. Default: current directory

Examples:
  sudo ./${SCRIPT_NAME} prepare --output-dir /tmp
  tar -xzf /tmp/ksh-offline-rhel9.6-x86_64.tar.gz
  cd ksh-offline-rhel9.6-x86_64
  sudo /path/to/${SCRIPT_NAME} install --rpm-dir .
  /path/to/${SCRIPT_NAME} verify
USAGE
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This mode must be run as root. Re-run with sudo."
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is not readable; cannot identify OS."

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
}

is_rhel_like() {
  [[ "${OS_ID}" == "rhel" ]] || [[ " ${OS_ID_LIKE} " == *" rhel "* ]]
}

check_rhel9() {
  local mode_name="${1:-run}"
  local major_version

  load_os_release
  major_version="${OS_VERSION_ID%%.*}"

  if ! is_rhel_like; then
    die "${mode_name} requires RHEL 9.x or a RHEL-like 9.x OS; detected '${OS_PRETTY_NAME}' (ID=${OS_ID}, ID_LIKE=${OS_ID_LIKE}, VERSION_ID=${OS_VERSION_ID})."
  fi

  if [[ "${major_version}" != "${TARGET_RHEL_MAJOR}" ]]; then
    die "${mode_name} requires RHEL 9.x; detected '${OS_PRETTY_NAME}' (VERSION_ID=${OS_VERSION_ID})."
  fi

  if [[ "${OS_VERSION_ID}" != "${TARGET_RHEL_VERSION}" ]]; then
    warn "${mode_name}: detected '${OS_PRETTY_NAME}' (VERSION_ID=${OS_VERSION_ID}); this script targets RHEL ${TARGET_RHEL_VERSION}. Continuing because this is RHEL 9.x."
  fi
}

need_arg() {
  local option_name="$1"
  local option_value="${2:-}"
  [[ -n "${option_value}" ]] || die "Missing argument for ${option_name}"
}

ensure_dnf_download() {
  require_command dnf

  if dnf -q download --help >/dev/null 2>&1; then
    return 0
  fi

  require_root
  info "dnf download is not available. Installing dnf-plugins-core."
  dnf -y install dnf-plugins-core

  if ! dnf -q download --help >/dev/null 2>&1; then
    die "dnf download is still unavailable after installing dnf-plugins-core."
  fi
}

collect_rpm_files() {
  local search_dir="$1"
  local -n rpm_array_ref="$2"
  mapfile -d '' rpm_array_ref < <(find "${search_dir}" -type f -name '*.rpm' -print0 | sort -z)
}

write_manifests() {
  local bundle_dir="$1"
  local rpm_dir="$2"
  shift 2
  local rpm_files=("$@")
  local rpm_file
  local relative_path
  local nevra

  {
    printf 'generated_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'target_package=%s\n' "${PACKAGE_NAME}"
    printf 'target_rhel_version=%s\n' "${TARGET_RHEL_VERSION}"
    printf 'host_arch=%s\n' "$(uname -m)"
    printf 'host_uname=%s\n' "$(uname -a)"
    printf '\n[/etc/os-release]\n'
    cat /etc/os-release
    printf '\n[rpm -q redhat-release]\n'
    rpm -q redhat-release || true
    printf '\n[dnf repolist --enabled]\n'
    dnf repolist --enabled || true
  } > "${bundle_dir}/OS-INFO.txt"

  {
    printf 'FILE\tNEVRA\n'
    for rpm_file in "${rpm_files[@]}"; do
      relative_path="${rpm_file#"${bundle_dir}/"}"
      nevra="$(rpm -qp --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' "${rpm_file}")"
      printf '%s\t%s\n' "${relative_path}" "${nevra}"
    done
  } > "${bundle_dir}/RPMS.txt"

  (
    cd "${bundle_dir}"
    find "${rpm_dir#"${bundle_dir}/"}" -type f -name '*.rpm' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  )
}

prepare_mode() {
  local work_dir="${PWD}/ksh-offline-work"
  local output_dir="${PWD}"
  local arch
  local bundle_dir_name
  local bundle_dir
  local rpm_dir
  local archive_path
  local download_help
  local dnf_download_args
  local rpm_files=()
  local rpm_file
  local has_ksh=0
  local package_name

  while (($#)); do
    case "$1" in
      --work-dir)
        need_arg "$1" "${2:-}"
        work_dir="$2"
        shift 2
        ;;
      --output-dir)
        need_arg "$1" "${2:-}"
        output_dir="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown prepare option: $1"
        ;;
    esac
  done

  check_rhel9 "prepare"
  require_command rpm
  require_command sha256sum
  require_command tar
  require_command find
  require_command sort
  require_command xargs
  require_command uname
  require_command grep
  ensure_dnf_download

  arch="$(uname -m)"
  bundle_dir_name="${BUNDLE_PREFIX}-${arch}"
  bundle_dir="${work_dir%/}/${bundle_dir_name}"
  rpm_dir="${bundle_dir}/rpms"
  archive_path="${output_dir%/}/${bundle_dir_name}.tar.gz"

  mkdir -p "${work_dir}" "${output_dir}"
  rm -rf -- "${bundle_dir}"
  mkdir -p "${rpm_dir}"

  download_help="$(dnf -q download --help 2>&1 || true)"
  dnf_download_args=(download --resolve --destdir "${rpm_dir}")
  if grep -q -- '--alldeps' <<<"${download_help}"; then
    dnf_download_args+=(--alldeps)
  fi
  dnf_download_args+=("${PACKAGE_NAME}")

  info "Downloading RPMs with: dnf ${dnf_download_args[*]}"
  dnf "${dnf_download_args[@]}"

  collect_rpm_files "${rpm_dir}" rpm_files
  ((${#rpm_files[@]} > 0)) || die "No RPM files were downloaded into ${rpm_dir}."

  for rpm_file in "${rpm_files[@]}"; do
    package_name="$(rpm -qp --qf '%{NAME}' "${rpm_file}")"
    if [[ "${package_name}" == "${PACKAGE_NAME}" ]]; then
      has_ksh=1
      break
    fi
  done
  ((has_ksh == 1)) || die "Downloaded RPM set does not contain package '${PACKAGE_NAME}'. Check enabled repositories and subscription status."

  write_manifests "${bundle_dir}" "${rpm_dir}" "${rpm_files[@]}"

  info "Creating archive: ${archive_path}"
  tar -czf "${archive_path}" -C "${work_dir}" "${bundle_dir_name}"

  info "Bundle created successfully."
  printf '%s\n' "${archive_path}"
}

find_sha256sums() {
  local rpm_dir="$1"
  local rpm_dir_abs
  local parent_dir_abs
  local candidate

  rpm_dir_abs="$(cd "${rpm_dir}" && pwd -P)"
  parent_dir_abs="$(cd "${rpm_dir_abs}/.." && pwd -P)"

  for candidate in "${rpm_dir_abs}/SHA256SUMS" "${parent_dir_abs}/SHA256SUMS"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

verify_sha256sums() {
  local rpm_dir="$1"
  local checksum_file
  local checksum_dir
  local checksum_base

  if ! checksum_file="$(find_sha256sums "${rpm_dir}")"; then
    die "SHA256SUMS was not found in '${rpm_dir}' or its parent directory. Use the extracted prepare bundle."
  fi

  checksum_dir="$(cd "$(dirname "${checksum_file}")" && pwd -P)"
  checksum_base="$(basename "${checksum_file}")"

  info "Verifying SHA256 checksums with ${checksum_file}"
  if ! (cd "${checksum_dir}" && sha256sum -c "${checksum_base}"); then
    die "SHA256 verification failed. The RPM bundle may be incomplete, modified, or extracted incorrectly."
  fi
}

validate_rpm_set() {
  local -n rpm_array_ref="$1"
  local host_arch
  local rpm_file
  local package_name
  local package_arch
  local has_ksh=0

  host_arch="$(uname -m)"

  for rpm_file in "${rpm_array_ref[@]}"; do
    package_name="$(rpm -qp --qf '%{NAME}' "${rpm_file}" 2>/dev/null)" || die "Invalid RPM file: ${rpm_file}"
    package_arch="$(rpm -qp --qf '%{ARCH}' "${rpm_file}")"

    if [[ "${package_arch}" != "noarch" && "${package_arch}" != "${host_arch}" ]]; then
      die "RPM architecture mismatch: ${rpm_file} is ${package_arch}, but this host is ${host_arch}."
    fi

    if [[ "${package_name}" == "${PACKAGE_NAME}" ]]; then
      has_ksh=1
    fi
  done

  ((has_ksh == 1)) || die "The RPM set does not contain package '${PACKAGE_NAME}'. Re-run prepare on the online RHEL ${TARGET_RHEL_VERSION} host."
}

select_transaction_rpms() {
  local -n all_rpms_ref="$1"
  local -n transaction_rpms_ref="$2"
  local rpm_file
  local package_name

  transaction_rpms_ref=()

  for rpm_file in "${all_rpms_ref[@]}"; do
    package_name="$(rpm -qp --qf '%{NAME}' "${rpm_file}")"

    if [[ "${package_name}" == "${PACKAGE_NAME}" ]]; then
      transaction_rpms_ref+=("${rpm_file}")
      continue
    fi

    if rpm -q "${package_name}" >/dev/null 2>&1; then
      info "Dependency package is already installed; leaving it untouched: ${package_name}"
      continue
    fi

    transaction_rpms_ref+=("${rpm_file}")
  done
}

run_rpm_transaction() {
  local -n transaction_rpms_ref="$1"
  local rpm_output

  ((${#transaction_rpms_ref[@]} > 0)) || die "No RPMs selected for installation."

  info "Testing RPM transaction with rpm -Uvh --test."
  if ! rpm_output="$(rpm -Uvh --test "${transaction_rpms_ref[@]}" 2>&1)"; then
    printf '%s\n' "${rpm_output}" >&2
    if grep -qiE 'failed dependencies|is needed by|conflicts with|is already installed|is newer than' <<<"${rpm_output}"; then
      die "RPM dependency test failed. The offline host is missing required packages or has incompatible installed versions. Re-run prepare on the same RHEL ${TARGET_RHEL_VERSION} architecture with matching repositories, then transfer the new bundle."
    fi
    die "RPM transaction test failed. See rpm output above."
  fi
  [[ -z "${rpm_output}" ]] || printf '%s\n' "${rpm_output}" >&2

  info "Installing with rpm -Uvh."
  if ! rpm_output="$(rpm -Uvh "${transaction_rpms_ref[@]}" 2>&1)"; then
    printf '%s\n' "${rpm_output}" >&2
    if grep -qiE 'failed dependencies|is needed by|conflicts with|is already installed|is newer than' <<<"${rpm_output}"; then
      die "RPM install failed because dependencies or installed package versions are not compatible. Use a bundle prepared on the same RHEL ${TARGET_RHEL_VERSION} architecture and repository set."
    fi
    die "RPM install failed. See rpm output above."
  fi
  [[ -z "${rpm_output}" ]] || printf '%s\n' "${rpm_output}" >&2
}

ensure_etc_shells() {
  local ksh_path

  ksh_path="$(command -v "${PACKAGE_NAME}" || true)"
  [[ -n "${ksh_path}" ]] || die "ksh command is not found after installation."

  if [[ ! -e /etc/shells ]]; then
    info "Creating /etc/shells."
    : > /etc/shells
  fi

  if grep -Fxq "${ksh_path}" /etc/shells; then
    info "/etc/shells already contains ${ksh_path}."
    return 0
  fi

  info "Adding ${ksh_path} to /etc/shells."
  printf '%s\n' "${ksh_path}" >> /etc/shells
}

install_mode() {
  local rpm_dir="${PWD}"
  local rpm_files=()
  local transaction_rpms=()

  while (($#)); do
    case "$1" in
      --rpm-dir)
        need_arg "$1" "${2:-}"
        rpm_dir="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown install option: $1"
        ;;
    esac
  done

  check_rhel9 "install"
  require_root
  require_command rpm
  require_command sha256sum
  require_command find
  require_command sort
  require_command grep
  require_command uname

  if rpm -q "${PACKAGE_NAME}" >/dev/null 2>&1; then
    info "${PACKAGE_NAME} is already installed. Skipping RPM installation and running verification."
    ensure_etc_shells
    verify_mode
    return 0
  fi

  [[ -d "${rpm_dir}" ]] || die "RPM directory does not exist: ${rpm_dir}"
  collect_rpm_files "${rpm_dir}" rpm_files
  ((${#rpm_files[@]} > 0)) || die "No RPM files found under: ${rpm_dir}"

  verify_sha256sums "${rpm_dir}"
  validate_rpm_set rpm_files
  select_transaction_rpms rpm_files transaction_rpms
  run_rpm_transaction transaction_rpms
  ensure_etc_shells
  verify_mode
}

get_ksh_version() {
  local ksh_path="$1"
  local version_output

  version_output="$("${ksh_path}" --version 2>&1 || true)"
  if [[ -z "${version_output}" ]]; then
    version_output="$("${ksh_path}" -c 'print -- ${.sh.version}' 2>&1 || true)"
  fi

  printf '%s\n' "${version_output}"
}

run_ksh_smoke_test() {
  local ksh_path="$1"
  local tmp_script
  local smoke_output

  tmp_script="$(mktemp /tmp/ksh-offline-smoke.XXXXXX)"
  cat > "${tmp_script}" <<'KSH'
typeset -i value=40
(( value += 2 ))
[[ "${value}" -eq 42 ]] || exit 10
print -- "${value}:ok"
KSH
  chmod 700 "${tmp_script}"

  if ! smoke_output="$("${ksh_path}" "${tmp_script}" 2>&1)"; then
    rm -f "${tmp_script}"
    printf '%s\n' "${smoke_output}" >&2
    die "ksh smoke test failed."
  fi
  rm -f "${tmp_script}"

  if [[ "${smoke_output}" != "42:ok" ]]; then
    printf '%s\n' "${smoke_output}" >&2
    die "ksh smoke test returned unexpected output."
  fi

  info "ksh smoke test output: ${smoke_output}"
}

verify_mode() {
  local package_query
  local ksh_path
  local version_output
  local version_line

  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown verify option: $1"
        ;;
    esac
  done

  check_rhel9 "verify"
  require_command rpm
  require_command mktemp
  require_command chmod
  require_command rm
  require_command head

  if ! package_query="$(rpm -q "${PACKAGE_NAME}" 2>&1)"; then
    printf '%s\n' "${package_query}" >&2
    die "Package '${PACKAGE_NAME}' is not installed."
  fi
  info "rpm -q ${PACKAGE_NAME}: ${package_query}"

  ksh_path="$(command -v "${PACKAGE_NAME}" || true)"
  [[ -n "${ksh_path}" ]] || die "rpm reports '${PACKAGE_NAME}' is installed, but command -v ${PACKAGE_NAME} failed. Check PATH or package contents."
  [[ -x "${ksh_path}" ]] || die "ksh path is not executable: ${ksh_path}"
  info "ksh path: ${ksh_path}"

  version_output="$(get_ksh_version "${ksh_path}")"
  [[ -n "${version_output}" ]] || die "Could not obtain ksh version output."
  version_line="$(printf '%s\n' "${version_output}" | head -n 1)"
  info "ksh version: ${version_line}"

  run_ksh_smoke_test "${ksh_path}"

  printf '%s\n' "ksh offline setup verification succeeded"
}

main() {
  local mode="${1:-}"

  case "${mode}" in
    prepare)
      shift
      prepare_mode "$@"
      ;;
    install)
      shift
      install_mode "$@"
      ;;
    verify)
      shift
      verify_mode "$@"
      ;;
    -h|--help)
      usage
      ;;
    "")
      usage
      exit 1
      ;;
    *)
      usage >&2
      die "Unknown mode: ${mode}"
      ;;
  esac
}

main "$@"
