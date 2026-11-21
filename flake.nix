{
  description = "Self-installing AI agent configuration (OpenAI Codex CLI, Claude Code, OpenCode, Gemini CLI, Hermes Agent).";

  outputs = { self, ... }: {
    # MCP servers from mcp/servers.json for Nix-configured agents (Hermes),
    # in Hermes' `mcp_servers` shape. Pure: reads the flake's own copy, so
    # changes reach consumers after `nix flake update agents`. A `~/` in a
    # stdio `command` is passed through as is (no $HOME at eval time), so
    # such servers should list the Nix agent in `skip` (as `browse` does).
    lib.mcpServers = target:
      let
        inherit (builtins) attrNames elem filter fromJSON listToAttrs readFile;
        servers = (fromJSON (readFile ./mcp/servers.json)).servers;
        keep = name:
          let s = servers.${name}; in
          (s.scope or "") == "global" && !(elem target (s.skip or [ ]));
        render = s:
          if s ? url then
            { inherit (s) url; } // (if (s.auth or "") == "oauth" then { auth = "oauth"; } else { })
          else
            { inherit (s) command; args = s.args or [ ]; } // (if s ? env then { inherit (s) env; } else { });
      in
      listToAttrs (map (name: { inherit name; value = render servers.${name}; })
        (filter keep (attrNames servers)));

    homeManagerModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.agents;
        link = relPath:
          config.lib.file.mkOutOfStoreSymlink "${cfg.repoPath}/${relPath}";

        # Runs sync.mjs live from the working tree (edits need no rebuild).
        # The user profile is on PATH so it finds the agent CLIs (claude,
        # codex) during activation too.
        agentsSync = pkgs.writeShellScriptBin "agents-sync" ''
          export PATH="${config.home.profileDirectory}/bin:$PATH"
          exec ${lib.getExe pkgs.nodejs} "${cfg.repoPath}/sync.mjs" "$@"
        '';
      in {
        options.agents = {
          repoPath = lib.mkOption {
            type = lib.types.str;
            default = "${config.home.homeDirectory}/.agents";
            example = "/home/alice/code/agents";
            description = ''
              Absolute filesystem path to the cloned `agents` repository on this
              machine. The Home-Manager module emits live `mkOutOfStoreSymlink`s
              that point at this path, so edits to files inside the repo take
              effect on the next CLI session without a Home-Manager rebuild.

              The default assumes the repo is cloned at `~/.agents`. Override if
              it lives elsewhere (e.g. an XDG path or a checkout outside `$HOME`).
            '';
          };

          sync.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Install the `agents-sync` command and run it on every activation:
              apply mcp/servers.json to each agent's MCP config and install
              the Claude Code plugins declared in settings.json that are
              missing (same as the shell installers).
            '';
          };
        };

        config = lib.mkMerge [
          {
            home.file = {
              ".claude/CLAUDE.md".source     = link "AGENTS.md";
              ".claude/agents".source        = link "agents";
              ".claude/commands".source      = link "commands";
              ".claude/hooks".source         = link "hooks";
              ".claude/settings.json".source = link "settings.json";
              ".claude/skills".source        = link "skills";
              ".codex/AGENTS.md".source      = link "AGENTS.md";
              ".config/opencode/AGENTS.md".source = link "AGENTS.md";
              ".gemini/GEMINI.md".source     = link "AGENTS.md";
            };

            home.activation.agentsRepoCheck =
              lib.hm.dag.entryBefore [ "linkGeneration" ] ''
                if [ ! -d "${cfg.repoPath}" ]; then
                  printf '\033[33mwarning:\033[0m agents.repoPath = %s does not exist on this machine; the symlinks created by the agents Home-Manager module will dangle until the repo is cloned there.\n' \
                    "${cfg.repoPath}" >&2
                fi
              '';
          }

          (lib.mkIf cfg.sync.enable {
            home.packages = [ agentsSync ];

            # Never fatal: a missing checkout or a network hiccup must not
            # abort the switch.
            home.activation.agentsSync =
              lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                if [ -f "${cfg.repoPath}/sync.mjs" ]; then
                  run ${agentsSync}/bin/agents-sync --quiet mcp sync \
                    || echo "agents-sync: mcp sync failed (continuing)" >&2
                  run ${agentsSync}/bin/agents-sync --quiet plugins sync \
                    || echo "agents-sync: plugins sync failed (continuing)" >&2
                fi
              '';
          })
        ];
      };
  };
}
