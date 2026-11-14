# Interactive SSH logins start in the project rather than the home directory.
# Commands run over SSH (ssh host command, the IDE's own connections) don't
# start login shells, so they keep their working directory.
case $- in
  *i*)
    if [ -n "$SSH_CONNECTION" ] && [ "$PWD" = "$HOME" ] && [ -r /etc/intellij-project ]; then
      __project=$(cat /etc/intellij-project)
      [ -n "$__project" ] && [ -d "$__project" ] && cd "$__project"
      unset __project
    fi
    ;;
esac
