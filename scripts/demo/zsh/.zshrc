# Shell for demo recordings: no personal config, a neutral prompt.
HISTFILE=/dev/null
PROMPT='%F{81}project%f %F{114}❯%f '
export PATH="${HYPRMUX_DEMO_DIR}/bin:$PATH"
export CLICOLOR=1 LSCOLORS=ExGxFxdxCxDxDxhbadExEx
# Output stays in the terminal instead of a pager.
export PAGER=cat GIT_PAGER=cat
clear
