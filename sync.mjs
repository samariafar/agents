#!/usr/bin/env node
// sync.mjs: apply this repo's manifests to every agent CLI's own config.
//
// The repo is the single source of truth, but each CLI owns and rewrites its
// config file, so this merges through the CLIs themselves where they offer a
// command for it (claude mcp, codex mcp) instead of symlinking or editing
// their files. Entries whose names are not in the manifest are never touched.
//
//   mcp sync             global servers from mcp/servers.json -> Codex,
//                        Claude Code (user scope), OpenCode, Gemini CLI;
//                        servers this tool added earlier that are no longer
//                        global are removed
//   mcp enable NAME...   add servers to the current project
//                        (.codex/config.toml, .mcp.json, opencode.json,
//                        .gemini/settings.json)
//   mcp disable NAME...  remove them from the current project
//   mcp list             show the manifest
//   plugins sync         install the Claude Code marketplaces/plugins that
//                        settings.json declares (extraKnownMarketplaces,
//                        enabledPlugins) but that are missing on this machine
//   (no arguments)       interactive menu when run in a terminal
//
// Options: -q/--quiet (first argument), --dir PATH (project root for
// enable/disable; default: the current directory).
//
// Hermes Agent is configured by Nix: the flake exports the same manifest as
// `lib.mcpServers` for its Home-Manager module (see flake.nix).
//
// Node >= 18, no dependencies; runs on Linux, macOS and Windows. Called by
// install.sh / install.ps1 and the flake's Home-Manager activation.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline/promises";
import { fileURLToPath } from "node:url";

const HOME = os.homedir();
const REPO = process.env.AGENTS_REPO || path.dirname(fileURLToPath(import.meta.url));
const STATE_DIR = process.env.XDG_STATE_HOME || path.join(HOME, ".local", "state");
const STATE_FILE = path.join(STATE_DIR, "agents", "mcp-managed.json");
const CODEX_BLOCK_START = "# >>> agents mcp (managed by ~/.agents/sync.mjs) >>>";
const CODEX_BLOCK_END = "# <<< agents mcp <<<";

let quiet = false;
const log = (msg) => quiet || console.log(`agents-sync: ${msg}`);
const warn = (msg) => console.error(`agents-sync: warning: ${msg}`);

// --- helpers ------------------------------------------------------------------

const readJson = (file, fallback) => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : fallback);

// JSONC (OpenCode's opencode.jsonc): drop comments and trailing commas,
// leaving string contents alone. Written back as plain JSON, so comments in
// a file this tool changes are lost (warned about in jsonFileBackend).
function stripJsonc(text) {
    let out = "";
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === '"') {
            let j = i + 1;
            while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
            out += text.slice(i, j + 1);
            i = j;
        } else if (c === "/" && text[i + 1] === "/") {
            while (i < text.length && text[i] !== "\n") i++;
            out += "\n";
        } else if (c === "/" && text[i + 1] === "*") {
            i = text.indexOf("*/", i + 2);
            if (i === -1) break;
            i++;
        } else out += c;
    }
    return out.replace(/,(\s*[}\]])/g, "$1");
}

// Every key of `want` deep-equals the same key in `have`. Extra keys in
// `have` (env vars or headers another installer added) don't count as drift.
const matches = (have, want) =>
    have !== null && typeof have === "object" && Object.entries(want).every(([k, v]) => same(have[k], v));

// Transport keys any agent uses; when an entry changes transport (stdio <->
// http) the old ones must not linger next to the new ones.
const TRANSPORT_KEYS = ["type", "command", "args", "url", "httpUrl"];
const mergeEntry = (existing, entry) => {
    const merged = { ...(existing ?? {}), ...entry };
    for (const k of TRANSPORT_KEYS) if (!(k in entry)) delete merged[k];
    return merged;
};

// Remove a config file this tool emptied, plus its folder when that is now
// empty too (e.g. a project's .codex/ or .gemini/ after `mcp disable`).
function removeFile(file) {
    fs.rmSync(file, { force: true });
    const dir = path.dirname(file);
    if (!path.basename(dir).startsWith(".")) return; // only agent dot-folders, never a project root
    try {
        fs.rmdirSync(dir); // fails (and is ignored) unless empty
    } catch {}
}

function writeFileKeepMode(file, text) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const mode = fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : 0o644;
    const tmp = `${file}.agents-sync.tmp`;
    fs.writeFileSync(tmp, text, { mode });
    fs.renameSync(tmp, file);
}

const writeJson = (file, data) => writeFileKeepMode(file, `${JSON.stringify(data, null, 2)}\n`);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function hasCommand(cmd) {
    try {
        execFileSync(cmd, ["--version"], { stdio: "ignore", shell: process.platform === "win32" });
        return true;
    } catch {
        return false;
    }
}

// On Windows the CLIs are .cmd shims, which Node only runs through a shell;
// the shell joins arguments unquoted, so quote them for cmd.exe/MSVC argv
// parsing (needed for the JSON that `claude mcp add-json` takes).
const winQuote = (arg) => `"${arg.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1")}"`;
const run = (cmd, args) =>
    process.platform === "win32"
        ? execFileSync(cmd, args.map(winQuote), { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], shell: true })
        : execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });

// --- manifest -----------------------------------------------------------------

function loadServers() {
    const { servers } = readJson(path.join(REPO, "mcp", "servers.json"), { servers: {} });
    for (const spec of Object.values(servers)) {
        if (spec.command?.startsWith("~/")) spec.command = path.join(HOME, spec.command.slice(2));
    }
    return servers;
}

// Neutral manifest entry -> one agent's config shape.
function render(target, spec) {
    if (spec.url) {
        if (target === "claude") return { type: "http", url: spec.url };
        if (target === "gemini") return { httpUrl: spec.url };
        if (target === "opencode") return { type: "remote", url: spec.url };
        return { url: spec.url }; // codex
    }
    if (target === "opencode") {
        const entry = { type: "local", command: [spec.command, ...(spec.args ?? [])] };
        if (spec.env) entry.environment = spec.env;
        return entry;
    }
    const entry = { command: spec.command, args: spec.args ?? [] };
    if (spec.env) entry.env = spec.env;
    return target === "claude" ? { type: "stdio", ...entry } : entry;
}

function wanted(servers, target, { scope, names } = {}) {
    const out = {};
    for (const [name, spec] of Object.entries(servers)) {
        if ((spec.skip ?? []).includes(target)) continue;
        if (scope && spec.scope !== scope) continue;
        if (names && !names.includes(name)) continue;
        out[name] = render(target, spec);
    }
    return out;
}

// --- user-scope backends --------------------------------------------------------
// read(): {name: entry} in the shape render() produces; set(name, entry); remove(name)

const claudeUser = {
    target: "claude",
    available: () => hasCommand("claude"),
    read() {
        const servers = readJson(path.join(HOME, ".claude.json"), {}).mcpServers ?? {};
        const out = {};
        for (const [name, s] of Object.entries(servers)) {
            out[name] = s.url
                ? { type: s.type ?? "http", url: s.url }
                : { type: "stdio", command: s.command, args: s.args ?? [], ...(s.env && Object.keys(s.env).length ? { env: s.env } : {}) };
        }
        return out;
    },
    set(name, entry, exists) {
        if (exists) run("claude", ["mcp", "remove", "-s", "user", name]);
        run("claude", ["mcp", "add-json", "-s", "user", name, JSON.stringify(entry)]);
    },
    remove: (name) => run("claude", ["mcp", "remove", "-s", "user", name]),
};

// Codex: `codex mcp add` blocks on an interactive OAuth login for servers
// that support it, so its config.toml is edited directly (marked block).
const codexHome = () => process.env.CODEX_HOME || path.join(HOME, ".codex");

// Gemini CLI, OpenCode and the project files are plain JSON(C) files; edit
// them directly (the CLI may not be installed on every machine, but its
// settings should still match). `keys` is the path to the server map:
// ["mcpServers"] for Claude/Gemini, ["mcp", "servers"] for OpenCode.
function jsonFileBackend(target, file, keys = ["mcpServers"]) {
    const load = () => {
        if (!fs.existsSync(file)) return { doc: {}, lossy: false };
        const text = fs.readFileSync(file, "utf8");
        const plain = file.endsWith(".jsonc") ? stripJsonc(text) : text;
        return { doc: JSON.parse(plain), lossy: plain !== text };
    };
    const getMap = (doc) => keys.reduce((node, k) => node?.[k], doc) ?? {};
    const setMap = (doc, map) => {
        const parents = [doc];
        for (const k of keys.slice(0, -1)) parents.push((parents.at(-1)[k] ??= {}));
        parents.at(-1)[keys.at(-1)] = map;
        // Prune what became empty, innermost first, so no `{}` is left behind.
        for (let i = keys.length - 1; i >= 0; i--) {
            if (Object.keys(parents[i][keys[i]]).length) break;
            delete parents[i][keys[i]];
        }
    };
    return {
        target,
        file,
        available: () => fs.existsSync(path.dirname(file)),
        read: () => getMap(load().doc),
        apply(setEntries, removeNames) {
            const { doc, lossy } = load();
            const current = getMap(doc);
            const mcp = { ...current };
            for (const name of removeNames) delete mcp[name];
            for (const [name, entry] of Object.entries(setEntries)) mcp[name] = mergeEntry(current[name], entry);
            if (same(mcp, current)) return false;
            setMap(doc, mcp);
            if (lossy) warn(`${file}: comments and trailing commas were not preserved`);
            if (Object.keys(doc).length) writeJson(file, doc);
            else removeFile(file); // nothing left but our servers: don't leave `{}` behind
            return true;
        },
    };
}

const geminiUser = jsonFileBackend("gemini", path.join(HOME, ".gemini", "settings.json"));

// OpenCode reads opencode.json or opencode.jsonc; edit whichever exists.
const openCodeFile = (dir) =>
    ["opencode.jsonc", "opencode.json"].map((f) => path.join(dir, f)).find((f) => fs.existsSync(f)) ?? path.join(dir, "opencode.json");
const openCodeDir = () => path.join(process.env.XDG_CONFIG_HOME || path.join(HOME, ".config"), "opencode");
const openCodeUser = () => jsonFileBackend("opencode", openCodeFile(openCodeDir()), ["mcp", "servers"]);

// --- project backends -----------------------------------------------------------

// Codex config.toml (user or project): our servers live in a marked block, so
// the rest of the file (other settings, hand-added servers) stays as written.
// Tables for manifest names found outside the block are hand-made copies;
// they are dropped so the block's version is the only one.
function codexToml(file) {
    const tomlString = (s) => JSON.stringify(s); // TOML basic strings share JSON escaping
    const tableName = (header) => header.match(/^\[mcp_servers\.("?)([^\]"]+)\1\]\s*$/)?.[2];
    const stripTables = (text, names) => {
        const out = [];
        let skipping = false;
        for (const line of text.split("\n")) {
            if (/^\s*\[/.test(line)) skipping = names.has(tableName(line.trim()));
            if (!skipping) out.push(line);
        }
        return out.join("\n").replace(/\n{3,}/g, "\n\n");
    };
    const parseBlock = (text) => {
        const start = text.indexOf(CODEX_BLOCK_START);
        const end = text.indexOf(CODEX_BLOCK_END);
        if (start === -1 || end === -1) return { before: text, after: "", block: "" };
        return {
            before: text.slice(0, start),
            block: text.slice(start + CODEX_BLOCK_START.length, end),
            after: text.slice(end + CODEX_BLOCK_END.length),
        };
    };
    const blockNames = (text) =>
        [...parseBlock(text).block.matchAll(/^\[mcp_servers\.("?)([^\]"]+)\1\]$/gm)].map((m) => m[2]);
    return {
        target: "codex",
        file,
        available: () => fs.existsSync(path.dirname(file)),
        // Presence only; the block is always rewritten from the manifest.
        read() {
            const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
            const outside = parseBlock(text);
            const loose = `${outside.before}\n${outside.after}`.split("\n").map((l) => tableName(l.trim())).filter(Boolean);
            return Object.fromEntries([...blockNames(text), ...loose].map((n) => [n, true]));
        },
        apply(setEntries, removeNames, servers) {
            const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
            const parsed = parseBlock(text);
            const managed = new Set(Object.keys(servers));
            const before = stripTables(parsed.before, managed);
            const after = stripTables(parsed.after, managed);
            const names = new Set(blockNames(text));
            for (const n of Object.keys(setEntries)) names.add(n);
            for (const n of removeNames) names.delete(n);
            const tables = [...names].sort().map((name) => {
                const e = render("codex", servers[name]);
                const lines = [`[mcp_servers.${tomlString(name)}]`];
                if (e.url) lines.push(`url = ${tomlString(e.url)}`);
                else {
                    lines.push(`command = ${tomlString(e.command)}`, `args = [${e.args.map(tomlString).join(", ")}]`);
                    if (e.env) lines.push(`env = { ${Object.entries(e.env).map(([k, v]) => `${tomlString(k)} = ${tomlString(v)}`).join(", ")} }`);
                }
                return lines.join("\n");
            });
            const block = tables.length ? `${CODEX_BLOCK_START}\n${tables.join("\n\n")}\n${CODEX_BLOCK_END}` : "";
            const rest = `${before.trimEnd()}${after.trimStart() ? `\n\n${after.trimStart()}` : ""}`.trim();
            const next = [rest, block].filter(Boolean).join("\n\n");
            if (next.trim() === text.trim()) return false;
            if (!next) {
                removeFile(file);
                return true;
            }
            writeFileKeepMode(file, `${next}\n`);
            return true;
        },
    };
}

const projectBackends = (root) => [
    codexToml(path.join(root, ".codex", "config.toml")),
    jsonFileBackend("claude", path.join(root, ".mcp.json")),
    jsonFileBackend("opencode", openCodeFile(root), ["mcp", "servers"]),
    jsonFileBackend("gemini", path.join(root, ".gemini", "settings.json")),
];

// --- commands -------------------------------------------------------------------

function mcpSync() {
    const servers = loadServers();
    const state = readJson(STATE_FILE, {});
    for (const backend of [codexToml(path.join(codexHome(), "config.toml")), claudeUser, openCodeUser(), geminiUser]) {
        if (!backend.available()) continue;
        const { target } = backend;
        try {
            const desired = wanted(servers, target, { scope: "global" });
            const current = backend.read();
            // Ours to remove: what we wrote before, plus manifest names that
            // aren't global for this agent (adopts hand-made copies once).
            const ours = new Set([...(state[target] ?? []), ...Object.keys(servers)]);
            const remove = [...ours].filter((n) => !(n in desired) && n in current);
            const set = Object.fromEntries(Object.entries(desired).filter(([n, e]) => !matches(current[n], e)));
            let changed;
            if (backend.apply) changed = backend.apply(set, remove, servers);
            else {
                for (const n of remove) backend.remove(n);
                for (const [n, e] of Object.entries(set)) backend.set(n, e, n in current);
                changed = remove.length > 0 || Object.keys(set).length > 0;
            }
            if (changed) log(`${target}: global = ${Object.keys(desired).join(", ") || "none"}; removed ${remove.join(", ") || "none"}`);
            state[target] = Object.keys(desired).sort();
        } catch (err) {
            warn(`${target}: ${err.stderr?.toString().trim() || err.message}`); // one broken agent must not block the rest
        }
    }
    writeJson(STATE_FILE, state);
}

function checkNames(servers, names) {
    const unknown = names.filter((n) => !(n in servers));
    if (unknown.length) throw new Error(`unknown server(s): ${unknown.join(", ")} (see \`agents-sync mcp list\`)`);
}

function codexTrusted(root) {
    const file = path.join(codexHome(), "config.toml");
    if (!fs.existsSync(file)) return false;
    const text = fs.readFileSync(file, "utf8");
    for (let dir = root; ; dir = path.dirname(dir)) {
        const header = text.indexOf(`[projects.${JSON.stringify(dir)}]`);
        if (header !== -1 && /^trust_level\s*=\s*"trusted"/m.test(text.slice(header).split(/\n\[/)[0])) return true;
        if (path.dirname(dir) === dir) return false;
    }
}

function mcpProject(names, root, enable) {
    const servers = loadServers();
    checkNames(servers, names);
    for (const backend of projectBackends(root)) {
        const entries = enable ? wanted(servers, backend.target, { names }) : {};
        const remove = enable ? [] : names;
        if (!enable && !fs.existsSync(backend.file)) continue;
        if (backend.apply(entries, remove, servers)) {
            log(`${backend.target}: ${enable ? "enabled" : "disabled"} ${names.join(", ")} in ${path.relative(root, backend.file)}`);
        }
    }
    if (enable && !codexTrusted(root)) warn(`Codex only loads .codex/config.toml in trusted projects; trust ${root} when Codex asks`);
}

function mcpList() {
    for (const [name, s] of Object.entries(loadServers())) {
        const where = s.url ?? [s.command, ...(s.args ?? [])].join(" ");
        const skip = s.skip?.length ? `  (not for: ${s.skip.join(", ")})` : "";
        console.log(`${name.padEnd(26)} ${(s.scope ?? "?").padEnd(8)} ${where}${skip}`);
        if (s.description) console.log(`${"".padEnd(35)} ${s.description}`);
    }
}

function pluginsSync() {
    if (!hasCommand("claude")) return warn("claude not on PATH; skipping plugins");
    // settings.json is the single declaration: Claude Code itself records
    // every `claude plugin install` there (~/.claude/settings.json links to
    // the repo's copy), so a list kept elsewhere would only drift from it.
    const settings = readJson(path.join(REPO, "settings.json"), {});
    const plugins = Object.entries(settings.enabledPlugins ?? {}).filter(([, on]) => on === true).map(([id]) => id);
    const dir = path.join(HOME, ".claude", "plugins");
    const known = new Set(Object.keys(readJson(path.join(dir, "known_marketplaces.json"), {})));
    const installed = new Set(Object.keys(readJson(path.join(dir, "installed_plugins.json"), {}).plugins ?? {}));
    for (const [name, { source: s = {} } = {}] of Object.entries(settings.extraKnownMarketplaces ?? {})) {
        if (known.has(name)) continue;
        const source = s.repo ?? s.url ?? s.path;
        if (!source) {
            warn(`marketplace ${name}: unsupported source in settings.json`);
            continue;
        }
        log(`claude: adding marketplace ${name} (${source})`);
        try { run("claude", ["plugin", "marketplace", "add", source]); } catch (err) { warn(`marketplace ${name}: ${err.message}`); }
    }
    for (const plugin of plugins) {
        if (installed.has(plugin)) continue;
        log(`claude: installing plugin ${plugin}`);
        try { run("claude", ["plugin", "install", plugin]); } catch (err) { warn(`plugin ${plugin}: ${err.message}`); }
    }
}

async function menu() {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    try {
        console.log("agents-sync\n  1) Sync global MCP servers to all agents\n  2) Enable MCP servers in this project\n  3) Disable MCP servers in this project\n  4) Install missing plugins\n  5) List MCP servers\n  q) Quit");
        const choice = (await rl.question("> ")).trim();
        if (choice === "1") return mcpSync();
        if (choice === "4") return pluginsSync();
        if (choice === "5") return mcpList();
        if (choice === "2" || choice === "3") {
            const servers = Object.entries(loadServers()).filter(([, s]) => choice === "3" || s.scope === "project");
            servers.forEach(([name, s], i) => console.log(`  ${i + 1}) ${name.padEnd(26)} ${s.description ?? ""}`));
            const picks = (await rl.question("Numbers (space-separated): ")).split(/[\s,]+/).filter(Boolean);
            const names = picks.map((p) => servers[Number(p) - 1]?.[0]).filter(Boolean);
            if (names.length) mcpProject(names, process.cwd(), choice === "2");
        }
    } finally {
        rl.close();
    }
}

const USAGE = "usage: agents-sync [-q] (mcp sync | mcp enable NAME... | mcp disable NAME... | mcp list | plugins sync) [--dir PATH]";

async function main(argv) {
    if (argv[0] === "-q" || argv[0] === "--quiet") {
        quiet = true;
        argv = argv.slice(1);
    }
    const dirIdx = argv.indexOf("--dir");
    if (dirIdx !== -1 && !argv[dirIdx + 1]) {
        console.error(`--dir needs a path\n${USAGE}`);
        process.exitCode = 2;
        return;
    }
    const root = path.resolve(dirIdx === -1 ? "." : argv[dirIdx + 1]);
    if (dirIdx !== -1) argv.splice(dirIdx, 2);
    const [group, cmd, ...names] = argv;
    if (!group) return process.stdin.isTTY ? menu() : console.error(USAGE);
    if (group === "mcp" && cmd === "sync") return mcpSync();
    if (group === "mcp" && cmd === "list") return mcpList();
    if (group === "mcp" && (cmd === "enable" || cmd === "disable") && names.length) return mcpProject(names, root, cmd === "enable");
    if (group === "plugins" && cmd === "sync") return pluginsSync();
    console.error(USAGE);
    process.exitCode = 2;
}

main(process.argv.slice(2)).catch((err) => {
    console.error(`agents-sync: ${err.message}`);
    process.exitCode = 1;
});
