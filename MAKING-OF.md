# Does jdtls-mcp actually help? Measuring it on Erasmus, one prompt at a time

*A first-person log of building and running an A/B test for
[jdtls-mcp](https://github.com/sunix/jdtls-mcp) — the tooling, the design
reversals, and (once there's data) the results themselves. Written in the
same blog-ish style as
[Erasmus's own MAKING-OF.md](../vidocq-workspace/erasmus/main/MAKING-OF.md),
but as a single living document rather than a per-milestone series — this is
one continuous investigation, not a sequence of shipped milestones. Updated
on request as the experiment progresses.*

*Last updated: 2026-08-20.*

## Why this exists

I wrote jdtls-mcp — a Java code-intelligence MCP server (hover, definitions,
references, diagnostics, completion) built on Eclipse JDT LS — without any
real data on whether it actually helps an LLM coding agent. Better code
quality? Fewer tokens burned per task, because the agent greps and re-reads
less? Or does it just sit there costing a few tokens for tool-definition
listings while the agent keeps doing what it already does? No idea. I was
also in the middle of building Erasmus, Vidocq's from-scratch Jakarta Bean
Validation implementation, which meant I had a real, ongoing Java codebase
and a real next milestone to throw at this instead of a toy example. Seemed
like the obvious opportunity to actually measure instead of guessing.

## Designing the experiment: forks, then worktrees

First instinct was to fork a single Claude Code conversation in two —
literally use `/branch` to get two sessions sharing identical history up to
a checkpoint, then diverge one with jdtls-mcp attached and one without. That
fell apart once file edits entered the picture: a shared conversation prefix
between two arms is dead weight, not signal, once you're driving each arm
headlessly with `claude -p` — both arms would pay for replaying that prefix
identically, and it doesn't test anything about the MCP server. Also, if the
task actually edits files, two arms sharing one working tree means one arm's
edits contaminate the other's starting state.

Landed on the opposite of shared state: **every run gets its own throwaway
git worktree**, branched off one pinned base commit, kept around afterward
(nothing resets or deletes it) so the actual generated code stays diffable
between runs, not just the token counts.

## Measuring tokens without trusting the UI

Turns out `/usage`'s dollar/token breakdown is gated to API-key accounts —
on a Claude Team subscription you only get quota-percentage bars and an
Attribution section that stays empty until an MCP tool is actually called.
Fix: drive each arm with `claude -p --output-format json`, whose `usage`
field (input/output/cache tokens) and `total_cost_usd` are populated the
same way regardless of subscription vs. API billing, since they're computed
client-side from the raw token counts the API returns on every request.

## The harness

Lives in this directory (`mcp-ab-test/`), driven by one file to edit
(`config.sh`, holding `REPO` and the task prompt) and five scripts:

- `00-install-jdtls-mcp.sh` — builds jdtls-mcp and runs a protocol-level
  smoke test (real MCP `initialize`/`tools/list` handshake) against its own
  source tree, so there's a PASS/FAIL before any real run is attempted.
- `01-run-without-jdtls.sh` / `02-run-with-jdtls.sh` — each creates its own
  fresh worktree off the pinned base commit and runs the identical task
  prompt, with jdtls-mcp attached via `--mcp-config` only in the second.
  Repeatable any number of times, in any order, to average out normal
  model-to-model variance.
- `03-compare.sh` — aggregates every run collected so far: per-run numbers,
  per-arm averages, delta between arms.
- `04-diff-runs.sh` — diffs one run against the base commit, or two runs
  against each other, to compare the *code* each arm actually produced
  (branch-to-branch `git diff`, since every worktree shares one `.git`).

Two rules the prompt has to follow for the comparison to mean anything:
identical wording in both arms (no hinting "use jdtls-mcp" in one and not
the other — that tests the hint, not the tool), and a task where symbol
navigation is genuinely useful, since a task that never touches Java symbols
can't show a difference either way.

## Picking a real task: Erasmus M3

The task in `config.sh` isn't a toy edit — it's the actual next Erasmus
milestone: object-graph cascading via `@Valid`, groups, and
`@GroupSequence` short-circuiting in `ErasmusValidator`. Told to Claude as a
self-contained prompt (read `CLAUDE.md`/`ROADMAP.md`, here's the scope, here
are the design constraints to not regress), with no reference to jdtls-mcp
at all. A milestone like this touches many call sites across
`ErasmusValidator` and its descriptor classes, which is exactly the shape of
work where "find every caller" / "go to definition" tooling should matter if
it matters at all.

## Turns out jdtls-mcp itself needed some fixes first

Before a single data point existed, just getting `00-install-jdtls-mcp.sh`
to pass green surfaced four real issues in jdtls-mcp itself:

- **[#17](https://github.com/sunix/jdtls-mcp/issues/17)** — the README's
  "recommended" install command 404s, because release assets are
  version-prefixed (`jdtls-mcp-v1.0.1-linux-x86_64.tar.gz`) but the
  documented command hardcodes an unversioned filename. **Fixed and merged**
  in [PR #21](https://github.com/sunix/jdtls-mcp/pull/21).
- **[#18](https://github.com/sunix/jdtls-mcp/issues/18)** — `tools/list`
  returns 8 tools; the README documents 7. `java_workspace_status` isn't
  mentioned anywhere.
- **[#19](https://github.com/sunix/jdtls-mcp/issues/19)** — a request sent
  before `notifications/initialized` is silently dropped, no JSON-RPC
  error, nothing on stderr — indistinguishable from a hang while debugging.
- **[#20](https://github.com/sunix/jdtls-mcp/issues/20)** — the launcher
  script has no Java-version floor check before `exec`-ing, so on a machine
  where the default `java` is <21 (this sandbox's default is 11) it fails
  deep inside the OSGi bootstrap instead of with a clear message. **Fixed
  and merged** in [PR #23](https://github.com/sunix/jdtls-mcp/pull/23).

Fixing these one at a time, PR per issue, reviewed and merged before moving
to the next. #18 also **fixed and merged**
([PR #22](https://github.com/sunix/jdtls-mcp/pull/22)).

#19 turned out to be a dead end worth recording: traced it all the way into
the MCP Java SDK's own `McpServerSession` — `exchangeSink.asMono()` never
resolves for a request received before `notifications/initialized`, and the
SDK's own source has a `TODO` acknowledging the exact gap. Not jdtls-mcp's
bug at all, and not fixed even in the SDK's latest `2.0.0` (jdtls-mcp is
pinned to `1.0.0`) — it's the SDK's own tracked
[issue #275](https://github.com/modelcontextprotocol/java-sdk/issues/275),
with two competing fix PRs already open there. Left #19 open on jdtls-mcp
as a tracking issue with the full trace commented, rather than closing it
or duplicating a report upstream.

## Running it for real: three harness bugs the self-tests didn't catch

Self-testing the harness against a throwaway repo (see "The harness" above)
verified the building blocks in isolation, but the first real run against
Erasmus surfaced three bugs that only showed up end-to-end:

- **`RESULTS_DIR` was a relative path.** Fine when tested by calling
  functions directly without changing directory; broke the moment the real
  script did `cd "$WORKTREE"` before writing the result file, so the output
  redirect resolved inside the erasmus worktree instead of `mcp-ab-test/`.
  Fixed by resolving it to an absolute path once, in `config.sh`.
- **The `claude` CLI wasn't on `PATH`** in the sandbox executing these
  scripts, even though it works fine interactively. Needed its actual
  location (`/root/.local/bin/claude`) prepended explicitly per invocation —
  unrelated to the user's own shell config, just how the execution sandbox
  is set up.
- **The sneaky one**: `--allowedTools` and `--mcp-config` are *variadic* CLI
  flags (`<tools...>`, `<configs...>`) — they greedily consume every
  following token, including the prompt itself if it comes last, leaving no
  actual prompt argument and producing a confusing `Input must be provided
  either through stdin or as a prompt argument` error. Fixed by moving the
  prompt right after `-p`, before any other flag, matching the pattern in
  the CLI's own documented examples.

## A near-miss: the prompt still pointed at `erasmus/main`

The task prompt in `config.sh` predates the worktree-per-run redesign and
still said "the Vidocq workspace
(`/root/codeberg/vidocq/vidocq-workspace/erasmus/main`)... read
`erasmus/main/CLAUDE.md`" — a hardcoded path nobody updated when the harness
moved from two fixed worktrees to one throwaway worktree per run. The first
real run followed that instruction literally and edited the **actual
`erasmus/main` checkout** directly instead of its own `run-1-without`
worktree: six files modified, one new file, genuine M3 cascading/groups
work, ~$2.42 spent before it was caught (via a stray IDE file-open
notification, not anything the harness itself flagged) and killed.

Confirmed via file mtimes that 100% of the changes were from that one run,
nothing pre-existing mixed in. Recovered with `git stash push -u` rather
than discarding anything — the work was real, just misdirected — then
dropped the stash once satisfied a clean rerun was the right call. Fixed the
prompt to reference "your current directory" generically instead of any
specific path, plus an explicit guardrail sentence ("don't reference or
touch any other checkout of this repo"). Re-verified the fix held with a
quick manual check partway through the next run, before trusting it to run
unattended.

Lesson for next time: sanity-check prompt *text* for stale hardcoded paths
whenever the harness *around* it changes shape — the scripts and the prompt
drifted out of sync silently, and nothing caught it until it actually ran.

## First real data: two clean runs

With all of the above fixed, got a clean pair — no contamination, real
work, real numbers:

| | without jdtls-mcp | with jdtls-mcp |
|---|---|---|
| cost | $3.43 | $3.73 |
| turns | 57 | 53 |
| output tokens | 58,218 | 77,993 |
| cache read | 5,447,677 | 5,020,076 |
| cache write | 152,631 | 175,144 |
| diff size | 902 insertions / 10 files | 1,216 insertions / 12 files |

Both arms independently implemented cascading + groups + `@GroupSequence`,
wrote their own test suite (14 and 18 tests respectively), and — notably —
both independently caught and fixed the same real bug (`getLeafBean()`
always returning the root bean instead of the actual cascaded bean), which
is a nice cross-check that both runs did genuinely careful work rather than
a shallow pass.

**The actual finding, though**: checked the "with" run's transcript for
`mcp__jdtls__*` tool invocations. The tool names were listed as available
in context (`java_hover`, `java_definition`, `java_references`, etc., via
the deferred-tools mechanism) — but **zero were ever called**. Not once,
across 53 turns of exactly the kind of multi-file, multi-symbol cascading
work jdtls-mcp's tools should be suited for. So this pair's cost delta
isn't "jdtls-mcp made it slightly more expensive" — it's "jdtls-mcp sat
completely unused, and the difference is noise plus the passive cost of
listing its tools in context." Not a verdict on the tool's usefulness yet;
a verdict on whether Claude reaches for it unprompted, which so far it
didn't.

## Trying to get it noticed: descriptions weren't even the problem

First attempt at explaining "never invoked": maybe the descriptions just
weren't compelling enough next to grep. Rewrote all five position-based/
search tools' descriptions on a separate `experiment/tool-descriptions`
branch (not `main` — untested changes stay off the branch other people
would pull) to explicitly sell the semantic-resolution angle ("resolved by
the compiler's semantic model, not text matching... prefer this over grep
whenever you need every call site of a method"), and to chain
`java_workspace_symbols`/`java_document_symbols` as the "find a position"
step feeding into `java_definition`/`java_references`, since most of these
tools require a position as input — a real structural mismatch with how an
agent naturally starts exploring code (from a name, not a position).

Reran with the improved descriptions (run #3): still zero invocations. Dug
into *why* and found the actual cause was one level down from descriptions
entirely — MCP tool schemas are deferred by default, and Claude has to
proactively call `ToolSearch` before it even sees a description, good or
bad. Grepped every transcript so far for `ToolSearch` calls: zero, across
every run. jdtls-mcp's tools had been invisible the whole time, regardless
of what their descriptions said.

Tried `ENABLE_TOOL_SEARCH=auto` next (run #4) — loads schemas upfront, but
only while the *total* deferred-tool budget across the whole session stays
under 10% of the context window. With every other deferred built-in
counted too (`CronCreate`, `WebFetch`, and the rest), that budget was
already blown before jdtls-mcp's 8 small tools were even considered. Still
zero.

## Building a warm-start relay

The precise per-server fix is `alwaysLoad: true` in the MCP config — forces
a server's tools into context at session start regardless of
`ENABLE_TOOL_SEARCH`. But it comes with a catch: the connection wait for an
`alwaysLoad` server is capped at ~5 seconds, and jdtls-mcp's own cold start
(Maven import + full JDT index) takes 60-100s. First attempt with
`alwaysLoad` alone (run #5) came back with **zero mentions of jdtls
anywhere** in the transcript — worse than deferred, since the connection
plausibly never completed in time and the tool just never appeared at all.

Since `McpApplication.java` does all of that slow setup work synchronously,
*before* the MCP transport even starts reading stdin, there's no "connected
but not ready" state to catch mid-flight — it's either completely silent or
fully ready the instant it responds at all. That means "start it earlier"
and "wait longer" solve the identical problem, and pre-warming turned out to
be the only lever that could actually work, since `alwaysLoad`'s 5s cap
reads like a fixed characteristic, not something `MCP_TIMEOUT` overrides.

Built `prewarm_jdtls`/`cleanup_prewarm_jdtls` (`config.sh`) and
`relay-warm-jdtls.sh`: launch the real jdtls-mcp process early against the
run's worktree, piped through a named FIFO, and block on a real
`initialize`/`notifications/initialized` handshake until it's genuinely
warm — not a fixed sleep. Point `--mcp-config` at the relay script instead
of the real launcher; Claude Code spawns the relay as "the server," unaware
a fully-indexed process has been running for a while already.

One real subtlety this raised: Claude Code performs its *own* handshake on
every connection, but the real server already went through that once during
pre-warming and has no clean path for a second `initialize` (the SDK source
has `// TODO handle situation where already initialized!`). So the relay
intercepts and locally fake-answers just the first two messages (reusing the
real `InitializeResult` captured during pre-warming for the `id` Claude
Code sent), then transparently relays everything after that — `tools/list`,
`tools/call` — to and from the already-warm process.

Hit one classic bug building it: opening a FIFO for writing blocks until a
reader exists, and my first cut opened the write end *before* launching the
server (the reader), deadlocking the whole script before it even printed
its first log line. Fixed by launching the server (backgrounded) first,
then opening the writer. Verified the whole relay end-to-end with a
simulated fake client — sent a real handshake + `tools/list` through it and
confirmed the response carried the true tool list — before spending a real
run on it.

## Run #6: a clean negative result (after a false alarm)

With pre-warm + relay wired into `02-run-with-jdtls.sh`, ran the real M3
task again (run #6): $4.15, 68 turns. Checked the transcript for
`mcp__jdtls__*` mentions — found **none at all**, which looked like another
connection failure.

It wasn't. A cheap diagnostic (`claude -p "say hi" --output-format
stream-json --verbose` against the same pre-warmed setup) showed
`"mcp_servers":[{"name":"jdtls","status":"connected"}]` and all 8 tools
sitting directly in the top-level tool list from turn one — genuinely
loaded, not deferred. The on-disk session transcript only logs a
`deferred_tools_delta` entry when a tool's deferred status *changes*;
tools loaded upfront via `alwaysLoad` are just present from the first
message with nothing to log, so grepping the transcript for "was it
available" only ever worked for the deferred runs — it silently stopped
being a valid check the moment `alwaysLoad` started working. The one
reliable signal, in every run, has always been actual `tool_use` blocks —
and those were genuinely zero in run #6 too.

So: fully connected, fully loaded upfront, good descriptions, real 68-turn
multi-file cascading/groups task — jdtls-mcp's tools were still never
called once. That's the cleanest, most favorable-to-the-tool trial run so
far, and the result didn't change.

## Pivot: telling it to prefer jdtls-mcp

Six runs of "does Claude reach for it unprompted" all came back the same
way, so the next question is different: if explicitly told to prefer it,
does it help? Added a new section to the shared `TASK_PROMPT` in
`config.sh` (same prompt text in both arms, still — it's a no-op instruction
in the "without" arm since the tools don't exist there):

Before, the prompt went straight from the opening paragraph into "Where
things stand":

> We're working on Erasmus, a from-scratch Jakarta Bean Validation 3.1
> implementation. Your current directory is a checkout of the erasmus
> repository — read `CLAUDE.md` and `ROADMAP.md` right here first, for
> conventions and the full milestone plan. Make all your changes within
> this directory; don't reference or touch any other checkout of this repo.
>
> ## Where things stand

Added, in between:

> ## Tool preference
>
> If jdtls-mcp's `java_*` MCP tools (`java_hover`, `java_definition`,
> `java_references`, `java_workspace_symbols`, `java_document_symbols`,
> `java_diagnostics`, `java_completion`, `java_workspace_status`) are
> available to you in this session, prefer them over grep/text search
> whenever you need to find a symbol's definition, its call sites, or
> references to it — they resolve the actual symbol semantically instead of
> matching text. Likewise, prefer `java_diagnostics` over invoking Maven
> when you just need to check for compile errors after an edit. Still use
> `./mvnw`/`./mvnw test` to actually run the test suite — diagnostics only
> reports compile errors, not test pass/fail. If these tools aren't
> available in this session, proceed as you normally would.

Launched run #7 (with-jdtls, pre-warmed + relayed, this new prompt) right
after. Worth being honest about what this changes methodologically: runs
1-6 measured whether availability alone changes behavior; run #7 onward
measures whether forced preference changes the outcome, cost, or quality —
a different question, and not directly poolable with the earlier "with"
runs in an average once there's more than one of them.

**Result — the first partial success**: one real invocation,
`mcp__jdtls__java_diagnostics`, called once on `ErasmusValidator.java`, with
Claude's own reasoning citing the instruction directly: *"Let's verify with
jdtls diagnostics rather than a full Maven build first."* The "prefer
`java_diagnostics` over Maven" half of the instruction worked. The "prefer
semantic search over grep" half didn't — `java_references`,
`java_definition`, `java_workspace_symbols` still got zero calls; all the
actual cascading/groups exploration still went through `Read`/`Grep`/`Edit`
(17 Reads, 21 Bash calls, 4 Writes). Cost and turns stayed in the same
range as every other run ($3.92, 61 turns), and the diff (910
insertions/11 files) is comparable in scope to the rest.

## Where the transcript actually lives

All of the invocation-checking above reads a specific file, so worth
recording exactly where it comes from. Claude Code writes every session's
full history to a JSONL transcript at:

```
~/.claude/projects/<project>/<session-id>.jsonl
```

`<project>` is the working directory the session started in, with every
non-alphanumeric character replaced by `-` — so
`/root/codeberg/vidocq/vidocq-workspace/erasmus/run-7-with` becomes the
directory `-root-codeberg-vidocq-vidocq-workspace-erasmus-run-7-with`. Since
`02-run-with-jdtls.sh` runs `claude -p` from inside that exact worktree,
each run gets its own project directory — no need to know the session ID
in advance, just list what's there:

```bash
f=$(ls -t /root/.claude/projects/-root-codeberg-vidocq-vidocq-workspace-erasmus-run-7-with/*.jsonl | head -1)
```

`ls -t | head -1` picks the most recently modified file, which matters if a
worktree's project directory ever accumulates more than one transcript
(re-running against the same path). To confirm a given transcript actually
belongs to a given result file rather than assuming it from the directory
name, cross-reference the session ID both files agree on:

```bash
jq -r .session_id results/run-7-with.json
# -> matches the <session-id> in the .jsonl filename above
```

The transcript is one JSON object per line — a message, a tool call, or
internal bookkeeping (like the `deferred_tools_delta` entries below) — and
Claude Code's own docs are explicit that this format is internal and can
change between versions, so it's fine for one-off investigation but not
something to build lasting tooling against.

## Getting the detection method right

"Was it invoked" has been the single most error-prone check in this whole
investigation — wrong twice, in two different ways, before landing on
something reliable.

**Wrong way #1** (runs 2-6): grepping the transcript for a
`deferred_tools_delta` entry mentioning jdtls's tool names, to check
whether the schema was even loaded. That only reflects a tool's *deferred*
status *changing* — it says nothing about an `alwaysLoad`ed tool, which is
present from message one with nothing to log. Run #6 initially looked like
a total connection failure for exactly this reason, corrected with a live
`stream-json` diagnostic instead (see "Run #6" above).

**Wrong way #2** (first read of run #7): grepping for a specific JSON key
order:

```bash
grep -o '"type":"tool_use","name":"[A-Za-z_]*"' "$transcript"
```

This assumes `"type"` always sits immediately before `"name"`, adjacent, in
that order — an accident of how one particular entry happened to serialize,
not a guarantee JSON makes about key order at all. Against run #7's
transcript this pattern matched *nothing*, even though a real invocation
was sitting right there.

**What actually works** — parse the JSON structurally instead of matching
text:

```bash
jq -r 'select(.message.content != null)
     | .message.content[]?
     | select(.type=="tool_use")
     | .name' "$transcript" | sort | uniq -c
```

Walks into `.message.content[]`, filters on the `type` field regardless of
where it sits in the object, pulls `.name` out properly. Run against run
#7, it immediately surfaced:

```
     21 Bash
     17 Edit
     17 Read
      4 Write
      1 mcp__jdtls__java_diagnostics
```

catching the one real call the grep pattern missed entirely. Re-ran this
exact `jq` command against runs 2, 3, 4, 5, and 6 to make sure those really
were zero — they were. The earlier "never invoked" conclusion for those
five holds; only the first read of run #7 was wrong. Every invocation
count in this document from here on is `jq`-verified against actual
`tool_use` blocks, not grepped or inferred from a tools-listing entry.

## Skills vs. an MCP-native nudge

Editing `TASK_PROMPT` to force a preference works for *this* harness, but
it only helps whoever happens to copy that instruction into their own
prompt. Raised the obvious next question: could the "prefer this over
grep" nudge live somewhere more durable — a Claude Code
[Skill](https://code.claude.com/docs/en/skills), or even inside jdtls-mcp
itself?

A Skill turned out to be a dead end for this specifically: it's a
Claude-Code-client mechanism (a `SKILL.md`, auto-triggered by relevance) —
there's no channel for an MCP server to ship one. MCP does have its own
"prompts" primitive, but that surfaces as a `/mcp__jdtls__promptname` slash
command a *person* types, not something Claude decides to invoke mid-task
on its own — not equivalent to a Skill's auto-trigger behavior at all.

What *is* MCP-native and does fit: the server's `instructions` field, set
via `SyncSpecification.instructions(String)` on the exact builder
`McpApplication.java` already uses. Per the docs, this is specifically what
Claude Code reads to decide whether to search a deferred server's tools at
all — described as working "similar to how skills work." jdtls-mcp never
calls `.instructions(...)` today. Unlike editing a task prompt, setting this
once in the server benefits every consumer automatically, with no
per-project copy-paste required — the right next experiment, and arguably
more valuable to jdtls-mcp long-term than anything provable from inside
this one Erasmus harness.

Implemented it on the same `experiment/tool-descriptions` branch, condensed
from the "what each tool could replace" table below into a short,
trigger-focused blurb (the field's job is deciding *whether to look
further*, not being the manual):

> Semantically-precise Java code intelligence backed by the real
> compiler/type model — not text matching. Prefer these tools over
> grep/text search whenever the task involves finding a Java symbol's
> definition, every real call site of a method or field (e.g. before a
> rename or signature change), or searching for a class/method by name
> across the workspace. Prefer `java_diagnostics` over running a full
> Maven build when you only need to check whether the code still compiles
> after an edit — still run the project's own test command to actually run
> the test suite; diagnostics only reports compile errors.

Rebuilt, confirmed it actually appears in the real `initialize` response's
`instructions` field (not just compiled), then — before opening a PR —
**removed** run #7's "Tool preference" section from `TASK_PROMPT` for the
next run. That's deliberate: leaving both in place would make it
impossible to tell whether any invocation came from the new server-side
field or the already-proven prompt-level instruction. Run #8 tests the
`instructions` field completely alone, same as runs 1-6's natural-discovery
condition otherwise.

## What each tool could replace

Requested alongside the skill/instructions question: a map of jdtls-mcp's
tools against what an agent's default toolkit (Read/Grep/Bash) would use
instead, and why the swap should be worth it. Only `java_diagnostics` has
actual evidence behind it so far (run #7) — the rest are hypotheses this
experiment hasn't yet gotten the chance to test, since the tools they'd
replace have never been invoked at all:

| Tool | Replaces | Why it should help |
|---|---|---|
| `java_workspace_symbols` | Grep/glob across the repo for a class or method name | Matches only real declared symbols, not text in comments/strings/unrelated files, and returns the exact file + position directly — skips the "grep, then open every candidate file to confirm" cycle |
| `java_document_symbols` | Reading a whole file just to see its shape | A structural outline (classes/methods/fields + positions) without paying for the full file's tokens — most useful on large files where only the shape matters |
| `java_definition` | Grep for a declaration, or manually tracing imports | Resolves the real declaration via the compiler's semantic model — correctly follows imports/inheritance/overloads, where grep can land on the wrong same-named symbol elsewhere in the codebase |
| `java_references` | Grep for a method/field name to "find every call site" | Avoids false positives from comments/strings/unrelated same-named symbols; this is the exact case (renames, signature changes) M3 should have used it for and never did, even when told to |
| `java_hover` | Opening a file to check one symbol's type/Javadoc | Cheaper than a full file read when only one symbol's info is needed, and resolves inferred/generic types that aren't literally spelled out in the source |
| `java_diagnostics` | `./mvnw compile` / `./mvnw test-compile` as a compile-error check | **Confirmed in run #7**: replaced a full Maven invocation with an instant in-memory compiler check during iterative editing |
| `java_completion` | Nothing, for this use case | Designed for interactive completion-as-you-type; not something an autonomous multi-file-editing agent naturally has a use for |
| `java_workspace_status` | Nothing directly — new capability | Lets an agent verify the workspace/index is actually ready before trusting other tools' results, or diagnose a Maven dependency failure without parsing raw build logs |

## Baking the nudge into the server: the `instructions` field, alone

Run #7 settled one thing: a "prefer jdtls-mcp" paragraph in the task prompt
gets `java_diagnostics` used. But a sentence pasted into one harness's prompt
helps nobody else. What I actually wanted to know was whether jdtls-mcp
could carry that nudge itself, so that anyone who connects it gets the
behaviour without knowing to ask for it.

Success had a precise shape. Run the harness with the *original* prompt —
the one from runs 1-6, no "Tool preference" section anywhere — then run the
one invocation check that survived the detection-method mess above:

```bash
jq -r 'select(.message.content != null)
     | .message.content[]?
     | select(.type=="tool_use")
     | .name' "$transcript" | sort | uniq -c
```

and find a `mcp__jdtls__*` line in what it prints. Run #7 is what that
looks like when it happens — this last line is the one I was hoping to see
come back with the prompt hint gone:

```
     21 Bash
     17 Edit
     17 Read
      4 Write
      1 mcp__jdtls__java_diagnostics
```

### Two spots in `McpApplication.java`

A housekeeping catch first. The description rewrite from runs 3 onward had
never actually been committed — it had lived as uncommitted edits, rebuilt
in place, through three real runs. I committed it (`97aac9e`) before
stacking anything on top, so the new change wouldn't sit on a dirty tree.

The change itself is two spots. Open `McpApplication.java` and look next to
the server name and version — a new constant, kept deliberately short,
because the docs describe this field's job as helping the client decide
*whether to look further*, not as the manual:

```java
private static final String SERVER_INSTRUCTIONS =
        "Semantically-precise Java code intelligence backed by the real compiler/type model — "
        + "not text matching. Prefer these tools over grep/text search whenever the task involves "
        + "finding a Java symbol's definition, every real call site of a method or field (e.g. "
        + "before a rename or signature change), or searching for a class/method by name across the "
        + "workspace. Prefer java_diagnostics over running a full Maven build when you only need to "
        + "check whether the code still compiles after an edit — still run the project's own "
        + "test command to actually run the test suite; diagnostics only reports compile errors.";
```

Then the one line that wires it in, on the same builder chain the server
was already using — nothing else in the bootstrap moves:

```java
var spec = McpServer.sync(transport)
        .serverInfo(SERVER_NAME, SERVER_VERSION)
        .instructions(SERVER_INSTRUCTIONS);
```

Compiling is not the same as reaching the wire. The pre-warm helper already
saves the real `InitializeResult` to a file for the relay's fake handshake,
so asking that file for the new field is a direct check that the text
actually goes out in the protocol — and it printed the paragraph straight
back:

```
$ jq '.instructions' "$WARM_INIT_RESULT_FILE"
"Semantically-precise Java code intelligence backed by the real compiler/type model — not text matching. Prefer these tools over grep/text search whenever the task involves finding a Java symbol's definition, […] diagnostics only reports compile errors."
```

### Skill, prompt, or server — where the "force" should live

This started from a question I put to Claude: rather than keep editing the
task prompt, could the preference live in a Claude Code skill — and could
that skill ship inside the MCP server? Claude ruled out both halves, for
different reasons. A Skill is a client-side mechanism (a `SKILL.md`,
auto-triggered by relevance) and there is no channel for an MCP server to
deliver one. MCP's own "prompts" primitive exists, but it surfaces as a
`/mcp__jdtls__…` slash command a person types — never something Claude
reaches for mid-task on its own. Then it went into the SDK source jdtls-mcp
actually builds against and found `SyncSpecification.instructions(String)`,
the field the Claude Code docs describe as guiding *when to search* a
server's tools, "similar to how skills work". That was the MCP-native
answer, and it had been sitting unused.

Claude wanted to open a PR right there. I said no: test it in a real run
first. Claude then did something I had not asked for but agreed with once
it explained itself — it removed run #7's "Tool preference" section from
the prompt before launching, on the grounds that with both nudges in place
I would have no way to tell which one produced any usage. A confounded run
would have told me nothing, so run #8 tests the field completely alone.

### Run #8: the field alone changed nothing about tool use

Same check, against run #8's transcript (session `188c125c…`, the same id
`results/run-8-with.json` reports, so I was reading the right file):

```
     22 Bash
     28 Edit
     19 Read
      9 Write
```

No `mcp__jdtls__` line. The `instructions` field, on its own, did not get a
single tool invoked — indistinguishable from runs 1-6. Only run #7, with
the instruction in the task prompt itself, has ever produced a call.

The run was not otherwise unremarkable, and it deserves recording honestly
rather than filing as "another zero":

| | run #1 (without) | run #7 (with, prompt nudge) | run #8 (with, `instructions` only) |
|---|---|---|---|
| cost | $3.43 | $3.92 | **$9.83** |
| turns | 57 | 61 | **79** |
| output tokens | 58,218 | 65,018 | 91,682 |
| cache read | 5,447,677 | 6,726,577 | 10,885,482 |
| diff | 902 ins. / 10 files | 910 ins. / 11 files | **1,864 ins. / 19 files** |

Roughly double every previous run. My first reflex was a stuck loop, so I
pulled every `Bash` command out of the transcript and read them in order.
It was not a loop — it was debugging. The run hit a real duplicate-violation
problem in group handling and tested hypotheses the way I would have. Watch
what this one-liner does to `ValidationContext.java`: it swaps the
identity-keyed visited set for a plain `HashSet`, to see whether identity
semantics were the culprit, then reran one test class and restored the file
from a backup it had taken first —

```bash
s=open(p).read().replace('Collections.newSetFromMap(new IdentityHashMap<>())','new java.util.HashSet<>()')
```

— and the same trick on `ErasmusValidator.java`, neutralising the
short-circuit branch with an `if (false && …)` to check whether early exit
was what dropped violations, before restoring that too. A dozen `Bash`
commands involved `mvnw`, mostly targeted `-Dtest=` runs rather than blind
full builds. It also rewrote `CLAUDE.md`'s architecture section to describe
the new `ValidationOrder` / `ValidationContext` / immutable-`PathImpl` flow
— something no earlier run had touched.

Its own closing report claimed a green reactor at 113 tests, up from 76.
That is a claim from the thing being measured, so I reran the suite myself
in the `run-8-with` worktree. The new group-sequence class is the one that
carries the bug the run was chasing; here is its fixture — an ordered
sequence over two groups, on a bean where both groups' constraints are
violated at once:

```java
@GroupSequence({Basic.class, Advanced.class})
public interface OrderedChecks {
}

private static final class Article {
    @NotBlank(groups = Basic.class)
    private final String title;

    @Size(min = 10, groups = Advanced.class)
    private final String body;
    // …
}
```

and the test that pins the short-circuit: both `title` and `body` are
invalid, but only `title` may be reported, because `Basic` fails first and
`Advanced` must never be evaluated —

```java
@Test
void groupSequence_shortCircuitsAtTheFirstFailingGroup() {
    Set<ConstraintViolation<Article>> violations =
            validator.validate(new Article("", "short", null), OrderedChecks.class);

    assertEquals(Set.of("title"), pathsOf(violations));
}
```

A duplicate-violation or non-short-circuiting implementation reports `body`
too and fails that `assertEquals`. Then `./mvnw -ntp test` from the
worktree root, watching the two new classes and the total:

```
[INFO] Tests run: 21, Failures: 0, Errors: 0, Skipped: 0 -- in io.vidocq.erasmus.core.internal.GroupsAndSequencesTest
[INFO] Tests run: 16, Failures: 0, Errors: 0, Skipped: 0 -- in io.vidocq.erasmus.core.internal.GraphValidationTest
[INFO] Tests run: 113, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

21 + 16 = 37 new tests, and 76 + 37 = 113 — the two numbers the run
reported check out against each other, and against a run I executed.

So the extra cost bought a deeper implementation, not wasted turns. It also
cannot be pinned on the `instructions` field: the tools it advertises were
never called, and the field itself is one short paragraph of passive
context. This is the run-to-run variance the harness README warned about
from day one — how far Claude decides to dig on an identical prompt can
swing the bill 2-3× on its own, which is exactly why one run per condition
was never going to be enough.

## Where it stands now

All four original jdtls-mcp issues resolved: #17, #18, #20 fixed and
merged; #19 traced to an upstream MCP Java SDK bug, documented, and left
open as a tracking issue rather than fixed here. The harness pre-warms
jdtls-mcp and relays Claude Code's connection to the already-warm process,
confirmed working via both a simulated-client test and a live
`stream-json` diagnostic, with tool-invocation checks `jq`-verified against
real `tool_use` blocks. On the `experiment/tool-descriptions` branch, the
description rewrite is committed (`97aac9e`) and the `instructions` field
is implemented, verified on the wire, and still uncommitted pending a
decision. Across eight runs — deferred, improved descriptions,
`ENABLE_TOOL_SEARCH=auto`, `alwaysLoad` timed out, `alwaysLoad` genuinely
connected, explicit prompt preference, and the server's own `instructions`
field alone — jdtls-mcp's semantic-search tools (`java_references`,
`java_definition`, `java_workspace_symbols`) have never been invoked once.
`java_diagnostics` is the only tool that has ever been used: once, in the
single run whose task prompt told Claude to prefer it over Maven. Nothing
baked into the server, at any level tried, has reproduced that without the
prompt.

## What's next

- Decide what to do with the `instructions` change now that it is proven
  harmless but also, on one run, ineffective: it still costs nothing and
  documents intent, so a PR is defensible — but the honest PR description
  says "no measured effect on invocation".
- Repeat run #7's condition (prompt-level preference) a few times to see
  whether `java_diagnostics` usage is consistent and whether
  `java_references`/`java_definition` ever get reached for when explicitly
  told to — that is now the only condition with any signal at all.
- Keep three pools apart and never average across them: unprompted
  (1-6, 8), prompt-preference (7), and whatever comes next.
- If explicit instruction still never gets the symbol-navigation tools
  called, that is the headline: visibility, descriptions, and even direct
  instruction are not the bottleneck — the shape of the tools (needing a
  file position before they can do anything) may be what keeps Claude on
  grep regardless of what it is told.
