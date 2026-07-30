# Transitional shell guard for legacy workspace Drive FUSE mounts.
case ":$PATH:" in
  *:"$HOME/.local/bin":*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

workspace_drive_ensure() {
  "$HOME/.local/bin/workspace-drive-mount" start >/dev/null 2>&1 || true
}

workspace_drive_guard() {
  case "$PWD" in
    "$HOME/workspace"|"$HOME/workspace"/*)
      if ! "$HOME/.local/bin/workspace-drive-mount" guard >/dev/null 2>&1; then
        printf '%s\n' "Workspace Drive mount is unavailable; refusing unsynced $HOME/workspace use." >&2
        printf '%s\n' "Run: workspace-drive-mount status" >&2
        cd "$HOME" || return
      fi
      ;;
  esac
}

case "$-" in
  *i*)
    workspace_drive_ensure
    workspace_drive_guard
    case "${PROMPT_COMMAND:-}" in
      *workspace_drive_guard*) ;;
      "") PROMPT_COMMAND="workspace_drive_guard" ;;
      *) PROMPT_COMMAND="workspace_drive_guard; $PROMPT_COMMAND" ;;
    esac
    ;;
esac
