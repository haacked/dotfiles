# Stage loop

This file continues the Stage loop section of the `go` skill's `SKILL.md`, which defines the loop base and how to find a stage's commit. "The single pass" means that file's Single pass section, and "Judgment calls" means the part of its Implement section with that name. Both stay in force here.

Each agent reads the plan file itself, so the parent never pastes the plan into a prompt. Give each one these *reading instructions*: the plan path and the stage number, and that it reads the whole plan except the other stages' text, plus the `**Notes**` and `**Check**` line of every completed stage. The Notes name the interfaces and test files that earlier stages added, and the check step runs the earlier Check commands.

When no stage has a commit and `next-action` names no stage substep, the loop is starting, and the tree must be clean, because each stage commit must hold only that stage's work. If it is dirty, the edits predate the loop: treat what to do with them as a hard-to-reverse question. Once the tree is clean or the user has settled the question, record `active-stage: implement`, and `simplify-scope: stages` unless `simplify-scope: branch` is already recorded.

Each stage keeps its working data under a `## Stage <N> progress` section at the end of the state file: the test files and failing tests from step 2, the check's gaps, and the implementer's notes. Write each item as the agent that produced it returns. Save `next-action: stage-<N>-<substep>` (`tests`, `implement`, `check`, or `commit`) before each substep starts.

Then, for each stage in order:

1. **Resume.** When `next-action` names a substep of this stage, an earlier run stopped there: go to that substep. The edits in the tree belong to it. A rerun test writer finishes the test files already present, a rerun implementer builds on the edits, and a rerun check judges them. Otherwise skip a stage that has a commit, and start any other at step 2.

2. **Tests.** Dispatch `unit-test-writer` in the foreground with the single pass's test-writer prompt, giving it the reading instructions in place of the plan's contents. Skip it when the single pass would skip its dispatch. Stage the files it wrote with `git add` once they are saved, so the check can tell the implementer's edits to them apart from the version the test writer wrote.

3. **Implement.** Dispatch a fresh `general-purpose` agent in the foreground. Its prompt contains the reading instructions, the test files and failing tests saved for this stage, the check's gaps when the progress section holds them, and these instructions:
   - Make the stage's tests and its `**Check**` command pass, and deliver every Success Criteria item. Stay inside the stage: work that a later stage owns is out of scope, even when it looks quick.
   - The tests were written from the plan alone. Fix guessed names, signatures, and import paths to match the real code, keeping each test's intent. Change what a test asserts only where it misreads the plan.
   - Leave no stubs, unwired functions, or TODO/FIXME markers in this stage's scope, and skip no tests.
   - The single pass's paragraph that starts "Then try to break the change", word for word.
   - Before reading a fourth file to understand a pattern, spawn an `Explore` agent with a narrow question.
   - The judgment-call rule from Judgment calls, word for word.
   - Do not stage, commit, or push.
   - Return the files changed, the `**Check**` result, the flagged calls, the question when it stopped on one, and notes a later stage needs, such as interfaces it added or surprises in the code.

   When the agent stops on a question, handle it as Judgment calls describes, then dispatch the implementer again. The plan's `## Decisions` now carries the answer.

4. **Check.** Dispatch a second fresh `general-purpose` agent in the foreground, one that did not write the code. Its prompt contains the reading instructions, the test files saved for this stage, and step 3's second instruction, the one about test edits, word for word. Instruct it to:
   - Read the stage's changes with `git diff HEAD`, plus the files `git ls-files --others --exclude-standard` lists.
   - Read the implementer's edits to the test files with `git diff -- <test files>`, and judge each edit by the test-edit instruction.
   - Run the stage's tests, the test files that earlier stages' `**Notes**` list, and the `**Check**` commands of this stage and every earlier stage, so a stage that breaks an earlier one fails here. At the last stage, also run the test suite, as the single pass runs it.
   - Confirm each Success Criteria item against the diff and the runs, and look for stubs, unwired code, TODO/FIXME markers, skipped tests, and criteria met by weakening a test.
   - Edit nothing.
   - Return PASS, or FAIL with each gap.

   On a FAIL, when the progress section holds no gaps yet, save the gaps there and `next-action: stage-<N>-implement` in one state-file write, then go back to step 3, whose prompt now carries the gaps. A FAIL when gaps are already saved means an implementer that had the gaps still failed. That is a hard-to-reverse question: "stage <N> failed its check," with the gaps. After the user answers, replace the saved gaps with this check's gaps and save `next-action: stage-<N>-implement` in one write, then go back to step 3.

5. **Commit.** When the stage has no commit yet, stage each file that `git status --porcelain` lists, by name, and run `git commit --allow-empty -F -` with the message `Implement $SLUG stage <N>: <stage name>` in a quoted heredoc, as the `commit` skill does. A stage name can hold backticks or `$`, which a double-quoted `-m` would expand. `--allow-empty` gives a stage that changed nothing a commit too, so the loop finds it done and the loop base exists. The `commit` skill is not used here because it reads the diff into main context. Next, unless the stage's `**Status**` in the plan file already reads `Complete`, add the implementer's notes and the stage's test files to the stage's `**Notes**`, because the next stage's agents read them, and then set `**Status**` to `Complete`. Then remove the stage's `## Stage <N> progress` section from the state file. The plan edit comes first so that the notes stay in the state file until the plan holds them. Tell the user in one line what landed: the stage name, the summary line of `git show --stat --format= HEAD`, and any flagged calls. Do not open the diff in main context; the Review step reads it.

After the last stage, check the files that `git diff --name-only <loop base> HEAD` lists for changed prompts. When any changed, dispatch the optimizer with the single pass's prompt, giving it the loop base in place of the diff so it runs `git diff <loop base> HEAD -- <files>` itself. Then dispatch a fresh `general-purpose` agent in the foreground with the optimizer's report. It applies the suggestions that sharpen a prompt while keeping the author's voice, runs the suite, reverts any suggestion that makes it fail, and returns the declined ones, one line each with why. Save those under `## Declined prompt suggestions` in the state file. Record `- implement: done` in the state file.
