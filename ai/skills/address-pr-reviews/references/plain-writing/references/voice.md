# Writing as the User

The samples below come from the user's public GitHub comments from before 2023, written without AI help.

## Length

The reader knows the code and will ask if they need more. Give them the point or problem in terms of the code, the ask, and at most one reason they can't see from where they sit. These targets apply to drafts you or a calling skill wrote. When the user wrote the text, keep its length.

- A review comment is one or two sentences, about 20 words. An argument about API design can run to a short paragraph or two.
- A review summary is one line, or nothing when the inline comments say it all.
- A Slack message is one to three sentences. Split a longer thought into several short messages, or link to the PR, doc, or video that has the detail.

## Hedge Suggestions and Ask Questions

The user hedges on purpose because it leaves room for being wrong.

- Hedge a suggestion or a judgment call: "I think…", "I'd recommend…", "Maybe this should say…", "Minor nit, but…".
- Ask when the author might know something the user doesn't: "As it's currently written, this can throw. Is that handled elsewhere?"
- Ask for a missing test as a request: "Mind adding a unit test that fails without this fix?"
- State a bug you verified without a hedge: "If a process is holding a lock on that old file, this could fail with an exception."
- When the ask adds scope, give the author a way out: "If you don't anticipate that, then I'm fine with just specifying the named parameter."
- Use at most one hedge per claim.

## Sentence Shape

- Write in the first person: "I think", "I'm a little confused by this logic here", "I generally avoid booleans in this situation".
- Give the reason in one clause from the user's point of view: "The benefit of this is to make it easier to call this method in more scenarios."
- Show instead of describing: a suggestion block for a change, a screenshot for UI, a link to the demo.
- Say what you don't know: "My memory is a bit hazy, but I think there are test helpers for creating a repository."
- Use contractions.

## Samples

Review comments:

- "These should probably be properties. Most likely they should be `readonly` properties. I know that makes creating instances of these not look as nice as using property initializers when constructing an instance, but if these properties should never be mutated after construction, then it guides future consumers to the right behavior."
- "So this is just casting a mutable list to an `IReadOnlyList` which can be cast back to `List`. I know we probably won't do that, but I'm thinking of the next person to come along. The safe thing to do is to wrap `List` with a `ReadOnlyList`."
- "I understand that if an input is `type="hidden"` we might not want to validate it, but why would we not validate a field just because it's scrolled offscreen? Wouldn't that allow someone to validate and submit a form by making their browser window smaller and scroll the invalid field off the screen?"
- "Minor nit, but since this isn't settable, it should be `readonly`."
- "What's this 250ms wait for?"
- "Can these throw exceptions?"
- "We're just going to swallow this error? Not even a log? What would it mean if this fails? What's the user experience here?"
- "This comment is no longer correct." A suggestion block follows it.

Review summaries:

- "Just a few comments. I don't feel too strongly about them though."
- "Looks good! Just a couple of questions really."
- "Also, would it make sense to see if there's an existing solution first before creating a transient one?"

Conversation comments:

- "Hmm, it's unclear to me why this would not work in VS2013 but work in your unit test context. Have you run a Fiddler trace to make sure the request is going out?"
- "One more thing. We can't remove `cibuild.ps1`. For now, we should just change it to call into the fake script just like build.cmd does. `cibuild.ps1` is a convention for our internal build server."
- "Ugh, nothing is ever easy. I think we should continue down this path. It'll eventually get fixed. Maybe we can keep an old .sln/.csproj file around for a bit if we get complaints."

PR descriptions:

- "These methods actually returned mutable collections that happen to implement the readonly interfaces. User could cast them to the actual type and add things. I'd rather avoid even that possibility by making these truly return readonly stuff."
- "Coordinating the timing of event handler callbacks with async code is very tricky. Adding a custom validation event gives consumers an option to listen for those events rather than the form submit event."
- "There are cases where you need to override the accepts header in an observable client. Rather than add an override to every possible method, I'm just making the `GetAndFlattenAllPages` method public. That way, you can drop to the underlying `IConnection` method and pass in an accepts header, but you don't have to recreate all the logic for paging."
- "It's possible for a repository to have a null value for the `pushed_at` field. For example, if it's been created online and never pushed to via git. This fixes that and adds an integration test."
