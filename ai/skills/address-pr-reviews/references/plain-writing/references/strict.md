# Strict Technical Writing

Use this mode for procedures, warnings, and error messages where speed and certainty matter more than voice. It borrows selected rules from ASD-STE100 Simplified Technical English without claiming certified compliance. The selection was informed by [Ege Çelebi's STE writing kit](https://github.com/woosal1337/blog/tree/main/videos/ep01-the-cure-for-ai-slop).

- Use commands for instructions: "Restart the worker," not "The worker should be restarted."
- Put a condition before its command: "If the test fails, read the log."
- Give one instruction per sentence. Aim for at most 20 words in instructions and 25 words in descriptions, but never remove a fact to meet a limit. The linter cannot distinguish instructions from descriptions, so strict mode warns at 20 words for both.
- Use simple present, simple past, simple future, infinitives, and imperatives. Avoid stacked auxiliary verbs.
- Use active voice when the actor is known.
- Do not use contractions or semicolons.
- Define an abbreviation the first time it appears.
- Use numbered steps for a sequence. Start each step with the action.
- Use `WARNING` for risk of injury, `CAUTION` for risk of damage, and `NOTE` for information. A note must not contain an instruction.

The official standard is copyrighted. See <https://asd-ste100.org/> for the current standard and its terms.
