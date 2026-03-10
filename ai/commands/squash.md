Squash all commits in the current branch (compared to the base branch) into a single commit.

1. Determine the base branch (main or master).
2. Run `git log <base>..HEAD` to review all commits being squashed.
3. Soft-reset to the base branch's merge-base point.
4. Create a single new commit whose message describes the final state of all changes — not the individual steps taken. Use present tense imperatives.
5. Show the result with `git log --oneline <base>..HEAD`.
