# fnm
export FNM_PATH="${HOME}/.local/share/fnm"
if [ -d "$FNM_PATH" ]; then
  if ! echo "$PATH" | grep -q "$FNM_PATH"; then
    export PATH="${FNM_PATH}:${PATH}"
  fi
  eval "$(fnm env --use-on-cd)"
fi
