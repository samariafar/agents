{
  description = "Self-installing AI assistant configuration (Claude Code, OpenAI Codex CLI, Gemini CLI).";

  outputs = { self, ... }: {
    homeManagerModules.default = { config, lib, ... }:
      let
        cfg = config.agents;
        link = relPath:
          config.lib.file.mkOutOfStoreSymlink "${cfg.repoPath}/${relPath}";
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
        };

        config = {
          home.file = {
            ".claude/CLAUDE.md".source     = link "AGENTS.md";
            ".claude/agents".source        = link "agents";
            ".claude/commands".source      = link "commands";
            ".claude/hooks".source         = link "hooks";
            ".claude/settings.json".source = link "settings.json";
            ".claude/skills".source        = link "skills";
            ".codex/AGENTS.md".source      = link "AGENTS.md";
            ".gemini/GEMINI.md".source     = link "AGENTS.md";
          };

          home.activation.agentsRepoCheck =
            lib.hm.dag.entryBefore [ "linkGeneration" ] ''
              if [ ! -d "${cfg.repoPath}" ]; then
                printf '\033[33mwarning:\033[0m agents.repoPath = %s does not exist on this machine; the symlinks created by the agents Home-Manager module will dangle until the repo is cloned there.\n' \
                  "${cfg.repoPath}" >&2
              fi
            '';
        };
      };
  };
}
