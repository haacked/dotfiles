# Standup Output Skeletons

Both outputs carry the same content. Sections appear in this order: Completed, Agent-authored, Shepherded, Working on, Side quests, Discussion; omit optional sections (Agent-authored, Shepherded, Side quests) entirely when empty.

## Plain text archive file

Every item is a plain line. URLs appear in parentheses immediately after the phrase they belong to.

```text
Completed:
{Past-tense description with `code names` in backticks} ({PR URL})
{Combined entry: primary description} ({primary PR URL}) with {woven phrase} ({related PR URL}) ({sequential follow-up} ({URL}) and then {another follow-up} ({URL}))

Agent-authored (reviewed & landed by me):
{Description} ({PR URL}) with docs ({docs PR URL})

Shepherded (external PRs I reviewed & merged):
{Description} (by @{handle}) ({PR URL})

Working on:
{Description} ({PR URL} - draft)
{Description} ({PR URL} - needs review)
{Non-PR work item, plain text, no URL}

Side quests:
{Description} ({In progress | Completed}) ({PR URL})

Discussion:
{Playful "nothing" variant}
```

## HTML for clipboard

Every section uses `<p><b>Header:</b></p>` followed by `<ul>`. Every item, without exception, is an `<li>` inside the `<ul>`, regardless of whether it contains a link. In combined entries each woven phrase is its own `<a>`. Use `<code>` for method/code names and HTML-escape `&`, `<`, `>`.

```html
<p><b>Completed:</b></p>
<ul>
<li><a href="{PR URL}">{Past-tense description with <code>code names</code>}</a></li>
<li><a href="{primary PR URL}">{combined entry: primary description}</a> with <a href="{related PR URL}">{woven phrase}</a> (<a href="{URL}">{sequential follow-up}</a> and then <a href="{URL}">{another follow-up}</a>)</li>
</ul>
<p><b>Agent-authored (reviewed &amp; landed by me):</b></p>
<ul>
<li><a href="{PR URL}">{Description}</a> with <a href="{docs PR URL}">docs</a></li>
</ul>
<p><b>Shepherded (external PRs I reviewed &amp; merged):</b></p>
<ul>
<li><a href="{PR URL}">{Description}</a> (by @{handle})</li>
</ul>
<p><b>Working on:</b></p>
<ul>
<li>{Description} (<a href="{PR URL}">draft</a>)</li>
<li>{Description} (<a href="{PR URL}">needs review</a>)</li>
<li>{Non-PR work item, no link}</li>
</ul>
<p><b>Side quests:</b></p>
<ul>
<li><a href="{PR URL}">{Description}</a> ({In progress | Completed})</li>
</ul>
<p><b>Discussion:</b></p>
<ul>
<li>{Playful "nothing" variant}</li>
</ul>
```
