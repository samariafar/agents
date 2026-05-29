#!/usr/bin/env bash
#
# install.sh — symlink this agents repository into the dotfile directories
# read by Claude Code (~/.claude), OpenAI Codex CLI (~/.codex), and Gemini CLI
# (~/.gemini). Linux + macOS. NixOS users: use the flake's Home-Manager module
# instead — see README.md.

set -euo pipefail

usage() {
	cat <<-EOF
		Usage: ${0##*/} [--force] [--uninstall] [--help]

		Symlinks the agents repository into the dotfile directories of the
		AI coding CLIs (Claude Code, OpenAI Codex, Gemini) under \$HOME.

		Options:
		  --force      Replace existing non-symlink files (originals are backed
		               up to <path>.bak-<UTC-timestamp> first).
		  --uninstall  Remove only the links that point into this repo. Other
		               files under ~/.claude, ~/.codex, ~/.gemini are left alone.
		  --help, -h   Show this help and exit.
	EOF
}

resolve_repo_dir() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L ${src} ]]; do
		local d
		d="$(cd -P "$(dirname "${src}")" >/dev/null && pwd)"
		src="$(readlink "${src}")"
		[[ ${src} != /* ]] && src="${d}/${src}"
	done
	cd -P "$(dirname "${src}")" >/dev/null && pwd
}

if [[ -t 1 ]]; then
	c_reset=$'\033[0m'
	c_red=$'\033[31m'
	c_green=$'\033[32m'
	c_yellow=$'\033[33m'
	c_blue=$'\033[34m'
	c_bold=$'\033[1m'
else
	c_reset=''
	c_red=''
	c_green=''
	c_yellow=''
	c_blue=''
	c_bold=''
fi

log()  { printf '%s[info]%s %s\n' "${c_blue}"   "${c_reset}" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "${c_green}"  "${c_reset}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${c_yellow}" "${c_reset}" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "${c_red}"    "${c_reset}" "$*" >&2; }

detect_nixos() {
	[[ -f /etc/NIXOS ]] && return 0
	if [[ -f /etc/os-release ]]; then
		local id
		# shellcheck disable=SC1091
		id="$(. /etc/os-release && printf '%s' "${ID:-}")"
		[[ ${id} == nixos ]] && return 0
	fi
	return 1
}

# Refuses to symlink encrypted blobs into ~/.claude. If the repo is git-crypt
# locked, tries to auto-unlock via sops (the symmetric key is base64-encoded
# under `git_crypt_key:` in secrets.yaml, decrypted with the user's age key).
ensure_unlocked() {
	local probe="${REPO_DIR}/AGENTS.md"
	[[ -f ${probe} ]] || return 0
	if ! LC_ALL=C head -c 10 -- "${probe}" 2>/dev/null | grep -q $'\x00GITCRYPT\x00'; then
		return 0
	fi

	if ! command -v git-crypt >/dev/null 2>&1; then
		err "repo is git-crypt locked but git-crypt is not installed."
		err "    install via your package manager and re-run."
		exit 1
	fi

	local keysrc="${REPO_DIR}/secrets.yaml"
	if [[ ! -f ${keysrc} ]]; then
		err "repo is git-crypt locked and no encrypted key found at secrets.yaml."
		err "    unlock manually:  cd ${REPO_DIR} && git-crypt unlock /path/to/your/key"
		exit 1
	fi

	if ! command -v sops >/dev/null 2>&1; then
		err "repo is git-crypt locked. Install sops + age, or unlock manually:"
		err "    cd ${REPO_DIR} && git-crypt unlock /path/to/your/key"
		exit 1
	fi

	log "git-crypt: locked — auto-unlocking via sops"
	local tmpkey
	tmpkey="$(mktemp)"
	if ! sops --decrypt --extract '["git_crypt_key"]' -- "${keysrc}" 2>/dev/null | base64 -d > "${tmpkey}"; then
		rm -f -- "${tmpkey}"
		err "sops decrypt failed. Is SOPS_AGE_KEY_FILE set and the age key readable?"
		exit 1
	fi
	if ! (cd "${REPO_DIR}" && git-crypt unlock "${tmpkey}" >/dev/null 2>&1); then
		rm -f -- "${tmpkey}"
		err "git-crypt unlock failed."
		exit 1
	fi
	rm -f -- "${tmpkey}"
	ok "git-crypt: unlocked"
}

# "<repo-relative-source>|<home-relative-link>"
LINKS=(
	"AGENTS.md|.claude/CLAUDE.md"
	"agents|.claude/agents"
	"commands|.claude/commands"
	"hooks|.claude/hooks"
	"settings.json|.claude/settings.json"
	"skills|.claude/skills"
	"AGENTS.md|.codex/AGENTS.md"
	"AGENTS.md|.gemini/GEMINI.md"
)

REPO_DIR=""
FORCE=0
UNINSTALL=0

backup_path_for() {
	local path="$1"
	local ts
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	printf '%s.bak-%s' "${path}" "${ts}"
}

# Returns 0 if the link is now correct, 1 if blocked (non-symlink present, no --force).
install_one() {
	local rel_src="$1"
	local rel_dst="$2"
	local src="${REPO_DIR}/${rel_src}"
	local dst="${HOME}/${rel_dst}"

	if [[ ! -e ${src} ]]; then
		warn "skip: source missing in repo (${rel_src})"
		return 0
	fi

	if [[ -L ${dst} ]]; then
		local current
		current="$(readlink "${dst}")"
		if [[ ${current} == "${src}" ]]; then
			ok "exists: ~/${rel_dst}"
			return 0
		fi
		warn "replacing stale symlink: ~/${rel_dst} → ${current}"
		rm -f -- "${dst}"
	elif [[ -e ${dst} ]]; then
		if (( FORCE )); then
			local backup
			backup="$(backup_path_for "${dst}")"
			warn "backing up: ~/${rel_dst} → ${backup}"
			mv -- "${dst}" "${backup}"
		else
			err "would clobber non-symlink: ~/${rel_dst} (re-run with --force to back up + replace)"
			return 1
		fi
	fi

	mkdir -p -- "$(dirname -- "${dst}")"
	ln -s -- "${src}" "${dst}"
	ok "linked: ~/${rel_dst} → ${src}"
	return 0
}

uninstall_one() {
	local rel_src="$1"
	local rel_dst="$2"
	local src="${REPO_DIR}/${rel_src}"
	local dst="${HOME}/${rel_dst}"

	if [[ ! -L ${dst} ]]; then
		if [[ -e ${dst} ]]; then
			warn "not a symlink, leaving alone: ~/${rel_dst}"
		else
			log "absent: ~/${rel_dst}"
		fi
		return 0
	fi

	local current
	current="$(readlink "${dst}")"
	if [[ ${current} != "${src}" ]]; then
		warn "symlink points elsewhere, leaving alone: ~/${rel_dst} → ${current}"
		return 0
	fi

	rm -- "${dst}"
	ok "removed: ~/${rel_dst}"
}

do_install() {
	local blocked=0
	local entry rel_src rel_dst
	for entry in "${LINKS[@]}"; do
		rel_src="${entry%%|*}"
		rel_dst="${entry##*|}"
		if ! install_one "${rel_src}" "${rel_dst}"; then
			blocked=1
		fi
	done
	if (( blocked )); then
		err "one or more links could not be created; re-run with --force to overwrite (existing files will be backed up)."
		exit 1
	fi
	ok "install complete."
}

do_uninstall() {
	local entry rel_src rel_dst
	for entry in "${LINKS[@]}"; do
		rel_src="${entry%%|*}"
		rel_dst="${entry##*|}"
		uninstall_one "${rel_src}" "${rel_dst}"
	done
	ok "uninstall complete."
}

main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--force)     FORCE=1 ;;
			--uninstall) UNINSTALL=1 ;;
			--help|-h)   usage; exit 0 ;;
			*)
				err "unknown option: $1"
				usage >&2
				exit 2
				;;
		esac
		shift
	done

	if detect_nixos; then
		err "NixOS detected. \$HOME on NixOS is owned by Home-Manager — shell symlinks will fight HM activation."
		err "Use the flake's Home-Manager module instead (see README.md)."
		exit 1
	fi

	REPO_DIR="$(resolve_repo_dir)"
	log "repo: ${c_bold}${REPO_DIR}${c_reset}"
	log "home: ${c_bold}${HOME}${c_reset}"

	if (( UNINSTALL )); then
		do_uninstall
	else
		ensure_unlocked
		do_install
	fi
}

main "$@"
