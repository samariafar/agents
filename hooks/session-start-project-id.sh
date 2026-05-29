#!/usr/bin/env bash
# Maintain a stable UUID for each project and keep
# ~/.claude/projects/<slug> as a symlink to ~/.claude/projects/.by-uuid/<uuid>/
# so per-project state survives directory renames and moves.
#
# Triggered by Claude Code on SessionStart. Never blocks the session:
# any error is logged and the script exits 0.
#
# Per-project state is written to <project>/.claude/settings.local.json —
# NOT settings.json — because the project ID is per-machine and should
# not be committed by projects that share their settings.json. For
# projects that previously stored the ID in settings.json (legacy from
# an earlier version of this hook), the value is read once from there
# as a fallback so the UUID-to-state link survives the migration.

CLAUDE_DIR="${HOME}/.claude"
PROJECTS_DIR="${CLAUDE_DIR}/projects"
BY_UUID_DIR="${PROJECTS_DIR}/.by-uuid"
LOG_FILE="${BY_UUID_DIR}/hook.log"

mkdir -p "${BY_UUID_DIR}"

log() {
	printf '[%s] %s\n' "$(date -Iseconds)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

# --- 1. Determine cwd (from stdin JSON, fall back to $PWD) ---
cwd=""
if [[ ! -t 0 ]]; then
	input="$(cat)"
	if [[ -n ${input} ]]; then
		cwd="$(jq -r '.cwd // .project_dir // empty' <<<"${input}" 2>/dev/null)"
	fi
fi
[[ -z ${cwd} ]] && cwd="${PWD}"

# --- 2. Skip transient/system locations ---
case "${cwd}" in
	"${HOME}"|"/"|"/tmp"|"/var/tmp"|"/root")
		log "skip: cwd=${cwd} (skiplist)"
		exit 0
		;;
esac

# --- 3. Compute Claude Code's slug for this cwd (replace / with -) ---
slug="${cwd//\//-}"
slug_path="${PROJECTS_DIR}/${slug}"

# --- 4. Resolve UUID: settings.local.json -> legacy settings.json -> existing symlink -> generate new ---
project_claude="${cwd}/.claude"
settings_file="${project_claude}/settings.local.json"
legacy_file="${project_claude}/settings.json"
uuid=""

if [[ -f ${settings_file} ]]; then
	uuid="$(jq -r '._meta.projectId // empty' "${settings_file}" 2>/dev/null)"
fi

# Legacy fallback: prior versions of this hook wrote to settings.json. Migrate
# transparently — the next write below persists the value into settings.local.json.
if [[ -z ${uuid} && -f ${legacy_file} ]]; then
	uuid="$(jq -r '._meta.projectId // empty' "${legacy_file}" 2>/dev/null)"
	[[ -n ${uuid} ]] && log "migrate: read uuid=${uuid} from legacy settings.json for ${cwd}"
fi

# Self-heal: settings file missing the key but symlink still resolves to a UUID dir
if [[ -z ${uuid} && -L ${slug_path} ]]; then
	candidate="$(basename "$(readlink "${slug_path}")")"
	if [[ ${candidate} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
		uuid="${candidate}"
		log "self-heal: recovered uuid=${uuid} for ${cwd}"
	fi
fi

if [[ -z ${uuid} ]]; then
	uuid="$(uuidgen)"
	log "new: ${cwd} -> ${uuid}"
fi

# --- 5. Persist UUID into <cwd>/.claude/settings.local.json (merge, preserve other keys) ---
mkdir -p "${project_claude}"
if [[ -f ${settings_file} ]]; then
	tmp="$(mktemp)"
	if jq --arg id "${uuid}" '. + {_meta: ((._meta // {}) + {projectId: $id})}' "${settings_file}" >"${tmp}" 2>/dev/null; then
		mv "${tmp}" "${settings_file}"
	else
		rm -f "${tmp}"
		log "WARN: failed to merge into ${settings_file}"
	fi
else
	jq -n --arg id "${uuid}" '{_meta: {projectId: $id}}' >"${settings_file}" 2>/dev/null
fi

# --- 6. Ensure the canonical by-uuid dir exists ---
target_dir="${BY_UUID_DIR}/${uuid}"
mkdir -p "${target_dir}"

# --- 7. Reconcile ~/.claude/projects/<slug> ---
if [[ -L ${slug_path} ]]; then
	current="$(readlink "${slug_path}")"
	if [[ ${current} != "${target_dir}" ]]; then
		rm "${slug_path}"
		ln -s "${target_dir}" "${slug_path}"
		log "repoint: ${slug} -> ${uuid}"
	fi
elif [[ -d ${slug_path} ]]; then
	log "migrate: ${slug} (real dir) -> ${uuid}"
	find "${slug_path}" -mindepth 1 -maxdepth 1 -exec mv -n {} "${target_dir}/" \; 2>/dev/null
	if rmdir "${slug_path}" 2>/dev/null; then
		ln -s "${target_dir}" "${slug_path}"
	else
		log "WARN: ${slug_path} not empty after migrate; symlink not created"
	fi
elif [[ ! -e ${slug_path} ]]; then
	ln -s "${target_dir}" "${slug_path}"
	log "create: ${slug} -> ${uuid}"
fi

exit 0
