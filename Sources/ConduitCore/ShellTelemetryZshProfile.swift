import Foundation

/// Creates the private zsh startup shims for one Conduit-owned Shell runtime.
/// The endpoint token and identities live in owner-only files, never in the
/// environment inherited by child processes.
public enum ShellTelemetryZshProfile {
    public static func files(
        taskSessionID: String,
        runtimeAttemptID: String,
        shellExecutionID: String,
        token: String,
        socketPath: String,
        originalZdotdir: String
    ) -> [String: String] {
        let common = #"""
        typeset -g _conduit_shell_private_zdotdir="$ZDOTDIR"
        typeset -g _conduit_shell_original_zdotdir=\#(shellQuote(originalZdotdir))
        typeset -g _conduit_shell_socket=\#(shellQuote(socketPath))
        typeset -g _conduit_shell_token=\#(shellQuote(token))
        typeset -g _conduit_shell_task=\#(shellQuote(taskSessionID))
        typeset -g _conduit_shell_runtime=\#(shellQuote(runtimeAttemptID))
        typeset -g _conduit_shell_execution=\#(shellQuote(shellExecutionID))
        typeset -gi _conduit_shell_sequence=0
        typeset -gi _conduit_shell_active_sequence=0
        _conduit_shell_source_original() {
          local name="$1"
          local private="$ZDOTDIR"
          local original="$_conduit_shell_original_zdotdir"
          if [[ -r "$original/$name" ]]; then
            ZDOTDIR="$original"
            source "$original/$name"
            _conduit_shell_original_zdotdir="${ZDOTDIR:-$original}"
          fi
          ZDOTDIR="$private"
        }
        _conduit_shell_json_escape() {
          local input="$1"
          input=${input//\\/\\\\}
          input=${input//\"/\\\"}
          input=${input//$'\n'/\\n}
          input=${input//$'\r'/\\r}
          input=${input//$'\t'/\\t}
          input=${input//$'\b'/\\b}
          input=${input//$'\f'/\\f}
          REPLY="$input"
        }
        _conduit_shell_emit() {
          local phase="$1" sequence="${2:-}" exit_status="${3:-}"
          local cwd="$PWD" escaped json socket_fd acknowledgement
          _conduit_shell_json_escape "$cwd"
          escaped="$REPLY"
          json="{\"token\":\"$_conduit_shell_token\",\"taskSessionID\":\"$_conduit_shell_task\",\"runtimeAttemptID\":\"$_conduit_shell_runtime\",\"shellExecutionID\":\"$_conduit_shell_execution\",\"phase\":\"$phase\",\"shellPID\":$$,\"workingDirectory\":\"$escaped\""
          if [[ -n "$sequence" ]]; then json+=",\"commandSequence\":$sequence"; fi
          if [[ -n "$exit_status" ]]; then json+=",\"exitStatus\":$exit_status"; fi
          json+="}"
          zmodload zsh/net/socket 2>/dev/null || return 0
          zsocket "$_conduit_shell_socket" 2>/dev/null || return 0
          socket_fd=$REPLY
          print -r -- "$json" >&$socket_fd 2>/dev/null || {
            exec {socket_fd}>&-
            return 0
          }
          read -r -t 0.5 -u "$socket_fd" acknowledgement 2>/dev/null || true
          exec {socket_fd}>&-
        }
        _conduit_shell_preexec() {
          (( ++_conduit_shell_sequence ))
          _conduit_shell_active_sequence=$_conduit_shell_sequence
          _conduit_shell_emit command_started "$_conduit_shell_active_sequence"
        }
        _conduit_shell_precmd() {
          local command_status=$?
          if (( _conduit_shell_active_sequence > 0 )); then
            _conduit_shell_emit command_exited "$_conduit_shell_active_sequence" "$command_status"
            _conduit_shell_active_sequence=0
          fi
        }
        _conduit_shell_chpwd() { _conduit_shell_emit directory_changed }
        _conduit_shell_zshexit() { _conduit_shell_emit shell_exited }
        """#

        return [
            ".zshenv": """
            \(common)
            _conduit_shell_source_original .zshenv
            ZDOTDIR="$_conduit_shell_private_zdotdir"
            """,
            ".zprofile": """
            _conduit_shell_source_original .zprofile
            """,
            ".zshrc": """
            _conduit_shell_source_original .zshrc
            if [[ -o interactive ]]; then
              _conduit_shell_emit execution_started
              autoload -Uz add-zsh-hook
              add-zsh-hook preexec _conduit_shell_preexec
              add-zsh-hook precmd _conduit_shell_precmd
              add-zsh-hook chpwd _conduit_shell_chpwd
              add-zsh-hook zshexit _conduit_shell_zshexit
            fi
            if [[ ! -o login ]]; then ZDOTDIR="$_conduit_shell_original_zdotdir"; fi
            """,
            ".zlogin": """
            _conduit_shell_source_original .zlogin
            ZDOTDIR="$_conduit_shell_original_zdotdir"
            """,
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
