---
name: plain-writing
description: Write, rewrite, or review prose for other people in clear, direct English. Use for PR descriptions, review comments, plans, reports, documentation, and messages. Do not use for code, structured data, or text that must remain verbatim.
argument-hint: "[technical|strict|voice-match|review] [text or file]"
---

# Plain Writing

Make the text easy for its intended reader to understand on the first pass.

## Modes

- `technical` is the default mode, used whenever no mode word is given. Use it for PRs, reviews, plans, reports, documentation, and work messages.
- `strict` is for procedures, warnings, and error messages. Read [references/strict.md](references/strict.md) before writing.
- `voice-match` is for personal writing when the user supplies a writing sample. Read [references/voice-match.md](references/voice-match.md) before writing.
- `review` identifies unclear passages without rewriting them. For each one, quote the passage, say what makes it hard to read, and give the smallest useful change. That list of findings is the entire output for `review` mode.

When the text is a message the user sends to colleagues, also read [references/voice.md](references/voice.md) before writing. That covers Slack messages, review comments, replies, and summaries, issue comments, and PR descriptions. Reports, plans, and status updates don't use it, even when the user posts them.

When a reference file conflicts with a rule below, follow the reference file.

## Reading the Arguments

- If the first word of the argument is `technical`, `strict`, `voice-match`, or `review`, treat it as the mode and treat the rest as the source. Otherwise treat the whole argument as the source and use `technical`.
- If the source names a file that exists, edit that file in place.
- If the source is not a file path, treat it as literal text and return the edited text without writing to disk.
- If nothing remains after the mode word, or the argument is empty, edit the most recent draft prose in this conversation. That means the text you or a calling skill just produced. Ask which text to edit only when no such draft exists.

## Preserve the Source

- Keep the requested format.
- When the user wrote the source, or you can't tell who did, preserve every fact, number, condition, qualifier, citation, link, identifier, error string, and technical term that carries exact meaning. Keep the approximate level of detail. Cut repetition, not substance.
- When you or a calling skill wrote the draft, keep only what the reader needs to act or decide. Leave out what they already know, can see in a linked diff or document, or would ask for if they needed it. That usually means a step-by-step mechanism, how other code does the same thing, citations they don't need to act on, and a second statement of a consequence. Never drop a fact that the ask or decision depends on. Every fact you keep stays exact, including its numbers, identifiers, qualifiers, links, and error strings.
- Keep code blocks, inline code, commands, quotations, templates, checkboxes, headings, and required labels unchanged unless the user asks to edit them.
- Do not add facts, examples, opinions, certainty, humor, personality, or conclusions that are not in the source.
- Keep uncertainty when the source is uncertain. Clear writing must not become a stronger claim.

## Write Clearly

- Lead with the answer, result, decision, or concrete consequence.
- Use common words and direct verbs. Keep established technical terms when they are more precise than a simpler substitute.
- Put one idea in each sentence. Split sentences that make the reader hold the cause, mechanism, consequence, and exception at once.
- Describe what happens instead of naming an abstract category. Do not invent labels, metaphors, or shorthand that the reader must decode.
- Do not use a word as a verb when the reader knows it as a noun from the code or domain, such as gate, flag, scope, cover, mirror, or lock. Say what happens instead: write `an experiment.update policy requires approval for changes to release conditions` instead of `experiment.update gates release condition changes`, and `the flags whose changes no longer need approval once an organization is rolled out` instead of `the flags a rollout ungates`. Do not stack nouns when the reader can take one of them as the sentence's verb: write `approval policies for flags` instead of `flag approval policies`.
- Prefer active voice when naming the actor helps. Keep passive voice when the actor is unknown or irrelevant.
- Keep paragraphs focused and short. Use headings and lists only when they make the text easier to scan.
- Remove signposting, filler, hype, vague attribution, repeated summaries, generic conclusions, and chatbot closers.
- Do not deny a smaller claim to set up the real one. Write what is true instead of `it is not just a cache, it is a full index`.
- Do not end a sentence with an `-ing` clause that restates it. Cut `highlighting the need for review` or replace it with the fact it stands for.
- Do not make "Nothing" or "No X" the subject or object of a sentence. Put the real subject first and negate the verb: write `it doesn't change anything that already exists` instead of `nothing changes that wasn't already existing`, and `deleting the queue doesn't change any actions` instead of `deleting the queue changes no actions`. Keep `no` or `nothing` after `there is` or `there are`, and after a verb that says what something has, takes, returns, or contains, such as `has no tests`, `takes no arguments`, or `returns nothing`.
- Do not pad a list to three items for rhythm. Use as many items as the content has.
- Do not use an em dash or an en dash, in any mode including voice-match. Restructure the sentence with other punctuation or separate sentences.
- Allow natural contractions in technical mode. Do not force all sentences to the same length or rhythm.
- Explain uncommon jargon once. Do not explain terms the intended reader already knows.

## Finish

Before you return your answer, silently reread the result as its intended reader and fix whatever fails these checks. Never print the checklist, your answers to it, or any other self-assessment.

1. Is the main point in the first sentence or first useful line?
2. Is the requested action clear?
3. Does each sentence make sense without a second pass?
4. Did every fact you had to keep survive, with its technical tokens exact?
5. Can any sentence lose words without losing meaning or tone?

Before you return the text, check it with `python3 scripts/plain-writing-lint.py`, resolving `scripts/` against this skill's own directory. Pipe the text on stdin, or pass a file path when you edited a file. In strict mode, add `--strict` first. Treat the output as warnings, not a quality score. Fix real problems and ignore false positives.

In every mode except `review`, return only the final text, with no audit, intermediate draft, change summary, preamble, or closing offer, unless the user explicitly asks to see the changes. In `review` mode, return only the findings described above and no rewritten text.
