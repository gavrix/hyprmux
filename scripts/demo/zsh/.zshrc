# Shell for demo recordings: no personal config, a neutral prompt.
HISTFILE=/dev/null
PROMPT='%F{81}project%f %F{114}❯%f '
export PATH="${HYPRMUX_DEMO_DIR}/bin:$PATH"
export CLICOLOR=1 LSCOLORS=ExGxFxdxCxDxDxhbadExEx
# Output stays in the terminal instead of a pager.
export PAGER=cat GIT_PAGER=cat
# Short titles for the bar and tabs: the project at the prompt, the command while it runs.
precmd() { print -Pn "\e]2;project\a" }
preexec() { print -rn -- $'\e]2;'"$1"$'\a' }
clear
