#compdef docket

_docket() {
  _arguments \
    '--engine[Agent to run the review in]:engine:(claude codex)' \
    '--home[Docket state directory]:directory:_files -/' \
    '--dry-run[Report the commands that would run without starting anything]' \
    '(-h --help)'{-h,--help}'[Show help]' \
    '1:pull request:'
}

compdef _docket docket
