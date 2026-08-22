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

When a mode's reference file conflicts with a rule below, follow the reference file.

## Reading the Arguments

- If the first word of the argument is `technical`, `strict`, `voice-match`, or `review`, treat it as the mode and treat the rest as the source. Otherwise treat the whole argument as the source and use `technical`.
- If the source names a file that exists, edit that file in place.
- If the source is not a file path, treat it as literal text and return the edited text without writing to disk.
- If nothing remains after the mode word, or the argument is empty, edit the most recent draft prose in this conversation. That means the text you or a calling skill just produced. Ask which text to edit only when no such draft exists.

## Preserve the Source

- Preserve every fact, number, condition, qualifier, citation, link, identifier, error string, and technical term that carries exact meaning.
- Keep code blocks, inline code, commands, quotations, templates, checkboxes, headings, and required labels unchanged unless the user asks to edit them.
- Do not add facts, examples, opinions, certainty, humor, personality, or conclusions that are not in the source.
- Keep uncertainty when the source is uncertain. Clear writing must not become a stronger claim.
- Keep the requested format and approximate level of detail. Cut repetition, not substance.

## Write Clearly

- Lead with the answer, result, decision, or concrete consequence.
- Use common words and direct verbs. Keep established technical terms when they are more precise than a simpler substitute.
- Put one idea in each sentence. Split sentences that make the reader hold the cause, mechanism, consequence, and exception at once.
- Describe what happens instead of naming an abstract category. Do not invent labels, metaphors, or shorthand that the reader must decode.
- Prefer active voice when naming the actor helps. Keep passive voice when the actor is unknown or irrelevant.
- Keep paragraphs focused and short. Use headings and lists only when they make the text easier to scan.
- Remove signposting, filler, hype, vague attribution, repeated summaries, generic conclusions, and chatbot closers.
- Do not use an em dash or an en dash, in any mode including voice-match. Restructure the sentence with other punctuation or separate sentences.
- Allow natural contractions in technical mode. Do not force all sentences to the same length or rhythm.
- Explain uncommon jargon once. Do not explain terms the intended reader already knows.

## Finish

Before you return your answer, silently reread the result as its intended reader and fix whatever fails these checks. Never print the checklist, your answers to it, or any other self-assessment.

1. Is the main point in the first sentence or first useful line?
2. Is the requested action clear?
3. Does each sentence make sense without a second pass?
4. Did every fact and technical token survive?
5. Can any sentence lose words without losing meaning or tone?

Before you return the text, check it with `python3 scripts/plain-writing-lint.py`, resolving `scripts/` against this skill's own directory. Pipe the text on stdin, or pass a file path when you edited a file. In strict mode, add `--strict` first. Treat the output as warnings, not a quality score. Fix real problems and ignore false positives.

In every mode except `review`, return only the final text, with no audit, intermediate draft, change summary, preamble, or closing offer, unless the user explicitly asks to see the changes. In `review` mode, return only the findings described above and no rewritten text.
