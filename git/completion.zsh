# Uses git's autocompletion for inner commands. Assumes an install of git's
# bash `git-completion` script at $completion below (this is where Homebrew
# tosses it, at least).
# CREDIT: https://github.com/holman/dotfiles/blob/master/git/completion.zsh
completion='$(brew --prefix)/share/zsh/site-functions/_git'

if test -f $completion
then
  source $completion
fi