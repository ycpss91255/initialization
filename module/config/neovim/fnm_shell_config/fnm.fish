# fnm
set -gx FNM_PATH "$HOME/.local/share/fnm"
if test -d "$FNM_PATH"
  if ! echo "$PATH" | grep -q "$FNM_PATH"; then
    set -gx PATH $FNM_PATH $PATH
  end
  fnm env --use-on-cd --shell fish | source
end
