**Smallest complete change.** Before writing code, list every place the change must reach: callers, tests, fixtures, config, and exports. For each piece the plan does not spell out, take the first option on this list that fully works:

1. Leave it out. A feature, option, or extension point that neither the plan nor the task asks for does not get built. Flag each one left out as an easy-to-reverse call.
2. Reuse what the codebase already has, such as a helper, service, or pattern, the way the surrounding code uses it.
3. Use the standard library or a platform feature, unless the project has its own version.
4. Use a dependency the project already installs. Do not add a dependency to save a few lines.
5. Write the least code that works and that a reader understands on one read.

- The rule shrinks the solution, never the scope. Finish every part the change needs, including the callers, tests, and fixtures it breaks.
- Add no wrapper, abstraction, option, config, or type conversion that nothing in this change uses.
- Keep the codebase's existing layers, interfaces, and conventions.
- For a bug fix, find every caller of the function first, then fix the root cause once in the shared code.
- Code that moves or merges keeps its validation and error handling.
- Between two options of the same size, take the one that handles edge cases correctly.
- Never cut validation at trust boundaries, error handling that prevents data loss, security checks, or accessibility.
