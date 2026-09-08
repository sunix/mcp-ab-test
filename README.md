# jdtls-mcp A/B token-usage test

Measures whether attaching the [jdtls-mcp](https://github.com/sunix/jdtls-mcp)
server (Java code intelligence: hover, definitions, references, diagnostics,
completion) changes Claude Code's token usage on a given task, compared to
running the same task with no MCP server at all.

Every run gets its **own fresh git worktree**, branched off the same pinned
base commit, so no run ever shares mutable file state with another — and
the worktree is kept afterward (nothing resets or deletes it), so you can go
back later and diff exactly what any run changed, or diff two runs against
each other.

## Files

| File | Purpose |
| --- | --- |
| `config.sh` | **The only file you edit.** Sets `REPO` and `TASK_PROMPT`, and holds shared helpers/defaults. |
| `00-install-jdtls-mcp.sh` | Installs jdtls-mcp and runs a protocol-level smoke test against its own source tree. |
| `01-run-without-jdtls.sh` | Creates a fresh worktree, runs `TASK_PROMPT` in it with no MCP config. Repeatable. |
| `02-run-with-jdtls.sh` | Creates a fresh worktree, runs `TASK_PROMPT` in it with jdtls-mcp attached via `--mcp-config`. Repeatable. |
| `03-compare.sh` | Prints every run's token usage, per-arm averages, and the delta between arms; writes `results/comparison.txt`. |
| `04-diff-runs.sh` | Diffs one run against the base commit, or two runs against each other, to compare the *code* they produced. |
| `results/` | One `run-<N>-without.json` / `run-<N>-with.json` per invocation, plus `base-commit.txt` and `comparison.txt`. |

There's no setup step: the first call to `01` or `02` pins the base commit
(recorded in `results/base-commit.txt`) and every run since branches off that
same commit, so runs stay comparable even if `main` moves on later.

## Example: testing against `erasmus`

`erasmus` (a from-scratch Jakarta Bean Validation 3.1 implementation) is
cloned at `vidocq-workspace/erasmus/main` per `mani.yaml`, with `REPO` set to
it in `config.sh` already.

`config.sh`'s current `TASK_PROMPT` is not a toy example — it's the real M3
milestone task: implement object-graph cascading (`@Valid`), groups, and
`@GroupSequence` short-circuiting in `ErasmusValidator`, following the
project's TDD convention, updating `ROADMAP.md`, and writing a making-of post
per `doc/making-of/AGENTS.md`. It points Claude at the project's own
`CLAUDE.md`/`ROADMAP.md` rather than repeating their content inline, so
prompt and worktree docs can't drift out of sync with each other. See
`config.sh` for the exact wording — it's the source of truth, not this file.

Two things to keep in mind whenever you edit `TASK_PROMPT`:

- Write it as if talking to a cold session — no "as we discussed", and never
  mention jdtls-mcp. The whole point is comparing identical instructions with
  and without the tool available; if you hint at using it in one arm and not
  the other, you're no longer measuring the tool, you're measuring the hint.
- Pick a task where symbol navigation is genuinely useful (find-callers,
  find-definition, diagnostics) so the "with" arm has real opportunity to use
  it — a task that never touches Java symbols will show no difference either
  way, which isn't a meaningful result. A milestone like M3 qualifies:
  cascading/groups touches many call sites of `ErasmusValidator` and related
  descriptor classes across the module.

Because this particular prompt is a full milestone implementation rather
than a small edit, expect each run to take a long time and consume
significant tokens, and to leave behind a full worktree per run — budget
disk and token spend accordingly before running many repetitions per arm.

## Running it

```bash
cd /root/codeberg/vidocq/mcp-ab-test

./00-install-jdtls-mcp.sh    # once: install + PASS/FAIL smoke test

# run each arm as many times as you want, in any order — every call creates
# its own new worktree (erasmus/run-<N>-without or erasmus/run-<N>-with):
./01-run-without-jdtls.sh    # -> results/run-1-without.json, worktree erasmus/run-1-without
./02-run-with-jdtls.sh       # -> results/run-2-with.json,    worktree erasmus/run-2-with
./01-run-without-jdtls.sh    # -> results/run-3-without.json, worktree erasmus/run-3-without
./02-run-with-jdtls.sh       # -> results/run-4-with.json,    worktree erasmus/run-4-with

./03-compare.sh              # -> results/comparison.txt (token usage/cost)
```

More runs per arm reduce noise from normal model-to-model variance — a
single run each is a data point, not a verdict.

## Comparing token usage

`results/comparison.txt` lists every run's `input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_write_tokens`, and `total_cost_usd`, then the
per-arm average of each, then `with - without` on those averages. A negative
delta means the jdtls-mcp arm used fewer tokens/cost on average; positive
means more.

Note that `--output-format json` only reports final totals, not which tools
were actually called mid-task. To confirm jdtls-mcp's tools were genuinely
invoked (as opposed to sitting unused in context, which still costs a little
just for the tool listing), read the run's session transcript. Claude Code
writes one per session at
`~/.claude/projects/<project>/<session-id>.jsonl`, where `<project>` is the
working directory with every non-alphanumeric character replaced by `-` —
so each run's worktree gets its own directory and there's no session ID to
track down. Then count the actual `tool_use` blocks with `jq`:

```bash
f=$(ls -t ~/.claude/projects/-root-codeberg-vidocq-vidocq-workspace-erasmus-run-7-with/*.jsonl | head -1)
jq -r 'select(.message.content != null)
     | .message.content[]?
     | select(.type=="tool_use")
     | .name' "$f" | sort | uniq -c
```

A `mcp__jdtls__*` line in that output is an invocation; no such line means
none. Don't grep the transcript for a literal `"type":"tool_use","name":...`
string instead — JSON key order isn't stable, and that pattern silently
missed a real call once. `MAKING-OF.md` ("Getting the detection method
right") has the details and the verified output.

## Comparing the code each run produced

Since every run keeps its own worktree/branch, use `04-diff-runs.sh` to see
what actually got written, not just how many tokens it cost:

```bash
./04-diff-runs.sh --list                       # every run branch collected so far
./04-diff-runs.sh run-1-without                 # what run 1 changed vs. the base commit
./04-diff-runs.sh run-1-without run-2-with      # diff between two runs' resulting code
```

The two-argument form is the interesting one for this test: it shows
exactly how the "with jdtls-mcp" arm's implementation differs from the
"without" arm's, independent of the token-usage numbers — e.g. whether it
touched different call sites, structured the cascading logic differently,
or left something out the other arm caught. Because worktrees share the
main repo's `.git`, this works from anywhere and even after a worktree
directory has been removed, as long as its branch still exists.

## Cleanup

Each run leaves behind a worktree and a branch. List and remove them from
the repo's `main` checkout when you're done with a given run:

```bash
cd /root/codeberg/vidocq/vidocq-workspace/erasmus/main
git worktree list                          # see every run-<N>-* worktree
git worktree remove ../run-1-without        # drop one run's worktree
git branch -D run-1-without                 # and its branch, once you no longer need to diff it

# or, once you're fully done with the whole test:
git worktree list --porcelain | awk '/^worktree/{print $2}' | grep '/run-' | xargs -n1 git worktree remove
git branch --list 'run-*' | xargs git branch -D
```

Keep the branch (even after removing its worktree) for as long as you might
still want `04-diff-runs.sh` to reach it — deleting the branch is what
actually loses the ability to diff that run.

## License

[Eclipse Public License 2.0](LICENSE) — the same license as
[jdtls-mcp](https://github.com/sunix/jdtls-mcp).
