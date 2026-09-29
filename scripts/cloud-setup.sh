#!/usr/bin/env bash
#
# What the cloud environment's setup box runs, as root, before a worker session
# starts. After it, a fresh container can run everything in CLAUDE.md's
# "Build & Test" — including the integration suite.
#
#   scripts/cloud-setup.sh              install
#   scripts/cloud-setup.sh --dry-run    print the plan, touch nothing
#
# Nothing here is specific to one worker: it installs a toolchain and fetches a
# TypeDB, and is safe to re-run (every step is skipped when its result is
# already in place).
#
# ---------------------------------------------------------------------------
# Which versions, and why these
#
# CI's lint job — the one that runs `mix format --check-formatted`, credo and
# dialyzer, and so the one whose verdict a worker has to predict — is
# `elixir: "1.20", otp: "29"` in .github/workflows/ci.yml. That is what this
# installs.
#
# `.tool-versions` says `elixir main-otp-29`, and this deliberately does not
# follow it. `main-otp-29` is a build of Elixir's development branch: the
# published artefact is rebuilt as that branch moves (the copy on
# builds.hex.pm changed on 2026-09-27), so its checksum is not a fact you can
# pin — "verified against its published SHA-256" would mean "whatever it is
# today". CI never uses it, and the formatter is the sharp end: a `mix format`
# from Elixir main can produce a file that 1.20's `--check-formatted` rejects,
# which is a red CI run caused by the setup box rather than by the change.
# Changing `.tool-versions` is the coordinator's call, not this script's.
#
# Within a series this resolves the newest build, which is what
# `erlef/setup-beam` does with `otp-version: "29"`, so the box matches CI's
# semantics rather than drifting from them. Pin exactly when you need to:
#
#   OTP_VERSION=29.1.1 ELIXIR_VERSION=1.20.4 scripts/cloud-setup.sh
# ---------------------------------------------------------------------------

set -euo pipefail

readonly OTP_SERIES="${OTP_SERIES:-29}"
readonly ELIXIR_SERIES="${ELIXIR_SERIES:-1.20}"

# builds.hex.pm publishes one prebuilt per OS image, and Ubuntu 24.04 on amd64
# is what the cloud environment runs. There is no fallback to building from
# source: that takes half an hour and a compiler toolchain, and a setup box
# that silently takes it would look like a hang.
readonly BUILDS_HOST="builds.hex.pm"
readonly OTP_INDEX="https://${BUILDS_HOST}/builds/otp/amd64/ubuntu-24.04/builds.txt"
readonly OTP_BASE="https://${BUILDS_HOST}/builds/otp/amd64/ubuntu-24.04"
readonly ELIXIR_INDEX="https://${BUILDS_HOST}/builds/elixir/builds.txt"
readonly ELIXIR_BASE="https://${BUILDS_HOST}/builds/elixir"

readonly PREFIX="${PREFIX:-/usr/local}"
readonly PROFILE_SCRIPT="${PROFILE_SCRIPT:-/etc/profile.d/beam-locale.sh}"
readonly OTP_DIR="${PREFIX}/lib/erlang"
readonly ELIXIR_DIR="${PREFIX}/lib/elixir"

# The version the integration suite is written against, and the one
# docker-compose.yml pins. Keep the three in step.
readonly TYPEDB_VERSION="${TYPEDB_VERSION:-3.12.1}"
readonly TYPEDB_HOST="repo.typedb.com"
readonly TYPEDB_URL="https://${TYPEDB_HOST}/public/public-release/raw/names/typedb-all-linux-x86_64/versions/${TYPEDB_VERSION}/typedb-all-linux-x86_64-${TYPEDB_VERSION}.tar.gz"

# TypeDB publishes no checksum index, so this is one taken from a download that
# was then run. Verifying it on every fetch is still worth more than not
# verifying: it catches a truncated transfer and a substituted artefact, and a
# version bump has to update it deliberately.
readonly TYPEDB_SHA256="bf41d00525ce50f2f938bdcdbeb23a7f27dc1ec166e958987d2549c1673fc18f"
readonly TYPEDB_PREFIX="${TYPEDB_PREFIX:-/opt/typedb}"

DRY_RUN=false

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# -- output -----------------------------------------------------------------

say() { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
plan() { printf '    %s\n' "$*" >&2; }

die() {
  printf 'cloud-setup: %s\n' "$*" >&2
  exit 1
}

# A download that fails should say which host would not answer: on a box whose
# egress is filtered, that name is the whole diagnosis, and "curl: (6)" is not.
fetch() {
  local url="$1" dest="$2" host="$3"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --connect-timeout 30 --max-time 900 --output "$dest" "$url" ||
    die "could not download ${url} — is ${host} reachable from this box?"
}

# -- guards -----------------------------------------------------------------

require_supported_platform() {
  local os arch id version

  os="$(uname -s)"
  arch="$(uname -m)"

  [ "$os" = "Linux" ] ||
    die "written for Linux, found ${os}. Install Erlang and Elixir by hand, or extend this script."

  [ "$arch" = "x86_64" ] ||
    die "written for x86_64, found ${arch}. builds.hex.pm has no Ubuntu 24.04 prebuilt for it; extend this script or build from source."

  [ -r /etc/os-release ] ||
    die "no /etc/os-release, so this cannot tell which Linux it is on. Expected Ubuntu 24.04."

  # shellcheck disable=SC1091
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

  [ "$id" = "ubuntu" ] && [ "$version" = "24.04" ] ||
    die "written for Ubuntu 24.04, found ${id:-unknown} ${version:-unknown}. The prebuilt Erlang is linked against that image's libraries and will not run elsewhere."

  say "platform: ${id} ${version} ${arch} — supported"
}

require_tools() {
  local missing=()

  for tool in curl tar unzip sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done

  [ ${#missing[@]} -eq 0 ] ||
    die "missing: ${missing[*]}. Install them first (apt-get install -y ${missing[*]})."
}

# -- resolving a version ----------------------------------------------------
#
# Both indexes are `<name> <git-ref> <built-at> <sha256>` a line, newest build
# of a name last. Resolving reads the index once and returns the version and
# its checksum together, so the checksum can never belong to a different build
# than the one downloaded.

resolve_otp() {
  local index="$1" wanted="${OTP_VERSION:-}"

  if [ -n "$wanted" ]; then
    awk -v v="OTP-${wanted}" '$1 == v { print $1, $4 }' "$index" | tail -n 1
  else
    awk -v s="^OTP-${OTP_SERIES}(\\.|$)" '$1 ~ s { print $1, $4 }' "$index" |
      sort -V | tail -n 1
  fi
}

resolve_elixir() {
  local index="$1" wanted="${ELIXIR_VERSION:-}"

  if [ -n "$wanted" ]; then
    awk -v v="v${wanted}-otp-${OTP_SERIES}" '$1 == v { print $1, $4 }' "$index" | tail -n 1
  else
    awk -v s="^v${ELIXIR_SERIES}\\.[0-9]+-otp-${OTP_SERIES}$" '$1 ~ s { print $1, $4 }' "$index" |
      sort -V | tail -n 1
  fi
}

verify_sha256() {
  local file="$1" expected="$2" what="$3" actual

  actual="$(sha256sum "$file" | cut -d' ' -f1)"

  [ "$actual" = "$expected" ] ||
    die "${what}: checksum mismatch. builds.hex.pm published ${expected}, the download is ${actual}. Refusing to install it."

  say "    sha256 ok (${expected})"
}

# -- Erlang/OTP -------------------------------------------------------------

install_otp() {
  local index build name sha archive work

  step "Erlang/OTP ${OTP_VERSION:-${OTP_SERIES}.x}"

  index="$(mktemp)"
  fetch "$OTP_INDEX" "$index" "$BUILDS_HOST"

  build="$(resolve_otp "$index")"
  rm -f "$index"

  [ -n "$build" ] ||
    die "no OTP ${OTP_VERSION:-${OTP_SERIES}.x} build for ubuntu-24.04/amd64 on ${BUILDS_HOST}."

  name="${build%% *}"
  sha="${build##* }"

  if $DRY_RUN; then
    plan "download ${OTP_BASE}/${name}.tar.gz"
    plan "verify sha256 ${sha}"
    plan "install into ${OTP_DIR}, link erl/erlc/escript into ${PREFIX}/bin"
    return
  fi

  if [ -x "${OTP_DIR}/bin/erl" ] && [ "$(cat "${OTP_DIR}/.cloud-setup-version" 2>/dev/null)" = "$name" ]; then
    say "    ${name} already installed"
    return
  fi

  work="$(mktemp -d)"
  archive="${work}/${name}.tar.gz"

  say "    downloading ${name}"
  fetch "${OTP_BASE}/${name}.tar.gz" "$archive" "$BUILDS_HOST"
  verify_sha256 "$archive" "$sha" "$name"

  tar -xzf "$archive" -C "$work"

  rm -rf "$OTP_DIR"
  mkdir -p "$(dirname "$OTP_DIR")"
  mv "${work}/${name}" "$OTP_DIR"

  # The prebuilt carries absolute paths from the machine that built it; its own
  # `Install` rewrites them for where it now lives. Skipping this is the
  # classic way to end up with an `erl` that cannot find its own libraries.
  (cd "$OTP_DIR" && ./Install -minimal "$OTP_DIR" >/dev/null)

  printf '%s\n' "$name" >"${OTP_DIR}/.cloud-setup-version"

  for bin in erl erlc escript dialyzer typer; do
    ln -sf "${OTP_DIR}/bin/${bin}" "${PREFIX}/bin/${bin}"
  done

  rm -rf "$work"
  say "    installed: $("${PREFIX}/bin/erl" -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
}

# -- Elixir -----------------------------------------------------------------

install_elixir() {
  local index build name sha archive work

  step "Elixir ${ELIXIR_VERSION:-${ELIXIR_SERIES}.x} (OTP ${OTP_SERIES})"

  index="$(mktemp)"
  fetch "$ELIXIR_INDEX" "$index" "$BUILDS_HOST"

  build="$(resolve_elixir "$index")"
  rm -f "$index"

  [ -n "$build" ] ||
    die "no Elixir ${ELIXIR_VERSION:-${ELIXIR_SERIES}.x} build for OTP ${OTP_SERIES} on ${BUILDS_HOST}."

  name="${build%% *}"
  sha="${build##* }"

  if $DRY_RUN; then
    plan "download ${ELIXIR_BASE}/${name}.zip"
    plan "verify sha256 ${sha}"
    plan "install into ${ELIXIR_DIR}, link elixir/elixirc/mix/iex into ${PREFIX}/bin"
    plan "mix local.hex --force && mix local.rebar --force"
    return
  fi

  if [ -x "${ELIXIR_DIR}/bin/elixir" ] && [ "$(cat "${ELIXIR_DIR}/.cloud-setup-version" 2>/dev/null)" = "$name" ]; then
    say "    ${name} already installed"
  else
    work="$(mktemp -d)"
    archive="${work}/${name}.zip"

    say "    downloading ${name}"
    fetch "${ELIXIR_BASE}/${name}.zip" "$archive" "$BUILDS_HOST"
    verify_sha256 "$archive" "$sha" "$name"

    rm -rf "$ELIXIR_DIR"
    mkdir -p "$ELIXIR_DIR"
    unzip -q "$archive" -d "$ELIXIR_DIR"

    printf '%s\n' "$name" >"${ELIXIR_DIR}/.cloud-setup-version"

    for bin in elixir elixirc mix iex; do
      ln -sf "${ELIXIR_DIR}/bin/${bin}" "${PREFIX}/bin/${bin}"
    done

    rm -rf "$work"
  fi

  say "    installed: $("${PREFIX}/bin/elixir" --version | tail -n 1)"

  # Both packages fetch hex dependencies and compile rebar ones (cowlib and gun
  # under typedb_grpc), so a box without these cannot even run `mix deps.get`.
  step "hex and rebar"
  "${PREFIX}/bin/mix" local.hex --force >/dev/null
  "${PREFIX}/bin/mix" local.rebar --force >/dev/null
  say "    installed"
}

# -- the locale -------------------------------------------------------------

install_locale() {
  step "UTF-8 locale"

  # A container with no LANG boots the BEAM with latin1 name encoding, and then
  # every `mix` command opens with a paragraph telling you Elixir "may
  # malfunction". Measured on this image: `mix --version` prints that warning
  # with no LANG and nothing with `LANG=C.UTF-8`. It is not only noise — the
  # encoding decides how filenames reach the VM.
  #
  # C.UTF-8 rather than a generated en_US.UTF-8: Ubuntu 24.04 ships it, so
  # there is nothing to install and nothing to generate.
  if $DRY_RUN; then
    plan "write ${PROFILE_SCRIPT} exporting LANG=C.UTF-8 and LC_ALL=C.UTF-8"
    return
  fi

  if ! locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
    say "    C.UTF-8 not available; leaving the locale alone"
    say "    (export ELIXIR_ERL_OPTIONS=\"+fnu\" if mix warns about latin1)"
    return
  fi

  mkdir -p "$(dirname "$PROFILE_SCRIPT")"

  cat >"$PROFILE_SCRIPT" <<'PROFILE'
# Written by scripts/cloud-setup.sh. Without a UTF-8 locale the BEAM uses
# latin1 for filenames and Elixir warns on every command that it may
# malfunction.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
PROFILE

  chmod 0644 "$PROFILE_SCRIPT"

  # For the rest of this run too: /etc/profile.d is read by login shells, and
  # this process is not one, so without these the steps below would print the
  # very warning just fixed.
  export LANG=C.UTF-8 LC_ALL=C.UTF-8

  say "    ${PROFILE_SCRIPT}: LANG=C.UTF-8 LC_ALL=C.UTF-8"
}

# -- TypeDB -----------------------------------------------------------------

install_typedb() {
  step "TypeDB ${TYPEDB_VERSION} for the integration suite"

  if command -v docker >/dev/null 2>&1; then
    if $DRY_RUN; then
      plan "docker compose pull (image typedb/typedb:${TYPEDB_VERSION} from docker-compose.yml)"
      return
    fi

    local image="typedb/typedb:${TYPEDB_VERSION}"

    if docker image inspect "$image" >/dev/null 2>&1; then
      say "    ${image} already present"
      return
    fi

    say "    docker present; pulling ${image}"

    # Pre-pulling is the whole point of doing this in the setup box: the image
    # is ~200 MB, and a worker that pulls it mid-session pays for it inside the
    # first integration run, where it looks like a hanging test.
    #
    # Not fatal when it fails, and the reason is printed rather than guessed
    # at: the daemon may not be running, or Docker Hub may be rate-limiting
    # (429 from registry-1.docker.io is what an unauthenticated container gets
    # after a few pulls, and it says nothing about this box being broken).
    # Either way `scripts/typedb-server` can still start whatever is there.
    local output status=0
    output="$( (cd "$REPO_ROOT" && docker compose pull --quiet) 2>&1 )" || status=$?

    if [ "$status" -eq 0 ]; then
      say "    pulled"
    else
      say "    could not pull from docker.io — a worker can retry, or use the release tarball:"
      printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi

    return
  fi

  if $DRY_RUN; then
    plan "no docker: download ${TYPEDB_URL}"
    plan "verify sha256 ${TYPEDB_SHA256}"
    plan "install into ${TYPEDB_PREFIX}/typedb-all-linux-x86_64-${TYPEDB_VERSION}"
    return
  fi

  local target="${TYPEDB_PREFIX}/typedb-all-linux-x86_64-${TYPEDB_VERSION}"

  if [ -x "${target}/typedb" ]; then
    say "    already installed at ${target}"
    return
  fi

  local work archive
  work="$(mktemp -d)"
  archive="${work}/typedb.tar.gz"

  say "    no docker; downloading the Linux server release"
  fetch "$TYPEDB_URL" "$archive" "$TYPEDB_HOST"

  local actual
  actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  [ "$actual" = "$TYPEDB_SHA256" ] ||
    die "TypeDB ${TYPEDB_VERSION}: checksum mismatch. Expected ${TYPEDB_SHA256}, got ${actual}. Refusing to install it."
  say "    sha256 ok (${TYPEDB_SHA256})"

  mkdir -p "$TYPEDB_PREFIX"
  tar -xzf "$archive" -C "$TYPEDB_PREFIX"
  rm -rf "$work"

  say "    installed at ${target}"
}

# -- main -------------------------------------------------------------------

usage() {
  cat >&2 <<'USAGE'
usage: scripts/cloud-setup.sh [--dry-run]

  --dry-run   print what would be downloaded and where it would go, and touch
              nothing. It still reads builds.hex.pm, because the plan names the
              exact versions and checksums it would install.

environment:
  OTP_SERIES, ELIXIR_SERIES   which series to take the newest build of
  OTP_VERSION, ELIXIR_VERSION exact versions instead (e.g. 29.1.1, 1.20.4)
  TYPEDB_VERSION              default 3.12.1, must match docker-compose.yml
  PREFIX                      default /usr/local
  PROFILE_SCRIPT              default /etc/profile.d/beam-locale.sh
  TYPEDB_PREFIX               default /opt/typedb
USAGE
}

main() {
  case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    "") ;;
    *)
      usage
      exit 2
      ;;
  esac

  require_supported_platform
  require_tools

  if $DRY_RUN; then
    say ""
    say "DRY RUN — nothing below is written."
  elif [ "$(id -u)" != "0" ]; then
    die "installs into ${PREFIX} and ${TYPEDB_PREFIX}; run it as root (this is what the environment's setup box does)."
  fi

  install_locale
  install_otp
  install_elixir
  install_typedb

  step "done"
  if $DRY_RUN; then
    say "    plan only; run without --dry-run to install."
  else
    say "    erl, elixir and mix are on PATH; scripts/typedb-server starts TypeDB."
    say "    See docs/cloud-workers.md."
  fi
}

main "$@"
