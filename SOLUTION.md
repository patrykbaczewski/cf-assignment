# Solution: Terraform test agent

A Claude Code agent with four skills adds and updates `terraform test` files for the
modules a pull request changes. A GitHub Actions workflow runs it, checks its output,
runs the tests itself, commits the verified tests to the pull request and posts one
comment with the results and the agent's findings. The agent never changes
infrastructure code: it reports, people decide.

```text
pull request ─► detect ──────► agent ─────────► verify ──────────► publish
                which modules   Claude Code,     no LLM: checks     commit tests,
                (git diff)      read-only        patch, runs tests  update comment
```

Pull requests: [#3](https://github.com/patrykbaczewski/cf-assignment/pull/3) is the
example run, [#5](https://github.com/patrykbaczewski/cf-assignment/pull/5) a finding
fixed by a person, [#2](https://github.com/patrykbaczewski/cf-assignment/pull/2) the
baseline tests for the other seven modules (same agent, run locally per module,
reviewed before merge).

## 1. Where the agent and skills are defined and how they are used

| Path | What |
|---|---|
| `.claude/agents/terraform-test-engineer.md` | The agent: role, hard rules, tools, 60 turns at most |
| `.claude/skills/tf-change-analysis/` | Decision per module: `tests_added`, `tests_updated`, `no_tests_needed`, `skipped` |
| `.claude/skills/tf-test-authoring/` | How to write tests here: mocked provider, `override_data`, `expect_failures` |
| `.claude/skills/tf-test-run/` | Run tests only through the sandbox, at most 3 fixes, never weaken an assertion |
| `.claude/skills/tf-review-findings/` | Findings with `file:line` evidence and a fixed severity per checklist item |
| `.github/workflows/`, `.github/scripts/` | The workflow and its PowerShell scripts |

`Invoke-TestAgent.ps1` starts Claude Code headless (`claude -p --agent
terraform-test-engineer`) with the task, the diff and locked-down settings
(`.github/agent/`). The agent loads the skills with the `Skill` tool and must return
JSON matching `agent-result.schema.json`; a hook checks every tool use first. The same
agent and skills work in an interactive Claude Code session.

## 2. Decisions and what they cost

| Decision | Why | Cost |
|---|---|---|
| The agent only proposes. A job without the LLM checks its patch (only `modules/*/tests/*.tftest.hcl`; no deletions, links, binaries, credentials) and its text (no credentials), reruns the tests, then commits | An LLM can be wrong or steered by text it reads | Four jobs instead of one |
| Settings allow only the test script and no web; a hook blocks anything else, and any hook error blocks too | Settings alone once let a model write outside `tests/` | The agent cannot even list folders |
| Tests run in Docker: `init` with network, then `fmt` and `test` without, read-only, non-root, on a copy | `function-app` runs a script during plan; PR code is untrusted | Docker needed locally too |
| All tooling the workflow trusts lives in `.github/`, `.claude/` and `CLAUDE.md`; one step, an action loaded from `@main`, restores it from the base branch | A PR must not loosen the rules it is checked by; one boundary leaves nothing to forget | Agent changes work only after merge; scripts sit in a hidden folder |
| The comment shows the agent's claimed status next to the verified one | Summaries are AI-written; test results are facts | None |
| Own workflow, not GitHub Agentic Workflows | Same pattern, but a preview, no subscription token, our sandbox would likely not run there | We maintain the plumbing |
| `claude-opus-5-5` | On `data-factory`, haiku locked an insecure default into a test and wrote outside `tests/` | Cost per run |
| PowerShell 7.4 | The team's language; passes PSScriptAnalyzer | Fewer examples |

## 3. Example run: #3

A person made the fixed `EP1` plan of `function-app` a `sku_name` variable (`EP1`,
`EP2` or `EP3`). [Run 3](https://github.com/patrykbaczewski/cf-assignment/actions/runs/39065813482):

- **detect:** one module.
- **agent** (21 turns, 66 s): `tf-change-analysis` → read the diff and whole module →
  `tf-test-authoring`, `tf-review-findings` → wrote `tests/main.tftest.hcl` →
  `tf-test-run` → tests passed on the first try. One tool use (`ls`) blocked.
- **`tests_added`, 9 runs:** `EP1` by default, `EP3` accepted, `Y1` and `ep2` rejected,
  HTTPS, TLS, identity, names, wiring. `override_data` keeps the build script from running.
- **verify:** 9 of 9 pass, formatted, claims match.
- **publish:** commit and 5 findings, all older than this change. The worst: plain FTP
  allowed, with a test that fails on the current code. No test asserts insecure values.

In #5 a person fixed that finding; the agent added 4 runs and noted that the new default
stops FTP deployments for current callers.

## 4. What the tests can and cannot show

They show the module's logic at plan: validations, exact security settings, instances
and names from `for_each`, wiring between resources. They cannot show what Azure
decides: naming and SKU rules, API validation, whether a role is enough, real network
behaviour. The provider is mocked and scripts are replaced. Passing means "the module
does what its code says", not "it deploys".

## 5. How to run it

- **Prerequisites:** GitHub Actions, a secret `CLAUDE_CODE_OAUTH_TOKEN`
  (`claude setup-token`), a protected `main`.
- **In pull requests:** change `modules/**`. Fork pull requests get no secrets: no
  agent, but failing tests fail the check.
- **Locally** (PowerShell 7.4, Docker): `pwsh -File .github/scripts/Invoke-TerraformTest.ps1 -ModulePath modules/<name>`;
  the agent with `Invoke-TestAgent.ps1` in a scratch checkout (Claude Code 2.1.280+).
- **Checks:** actionlint, zizmor and PSScriptAnalyzer report nothing.

## 6. Assumptions

- Authors of same-repository pull requests are trusted; fork authors are not.
- Tests against a mocked provider are useful evidence; nothing is applied.
- The stack is out of scope and only reported.
- A person reviews and merges every pull request, including the agent's commits.

## 7. Limitations

- With `pull_request` the workflow file comes from the pull request: someone with write
  access can change it and read the secret.
- One session per pull request, 60 turns: new tests for many modules do not fit
  (seven test-only modules took 47).
- LLM judgement varies: one finding was `high`, then `medium`. With fixed severities 4 of
  5 matched; the fifth item's wording is now fixed.
- The agent's commit has `[skip ci]`, so as a required check it would get no result.
- Each run replaces the previous comment (GitHub keeps the edit history).
- Claude Code lets a tool use through when the hook times out (30 s); the hook takes
  about a second, and the verify job rechecks every write.
- A personal subscription token, not an organisation key with spending limits.

## 8. With many more modules, teams or repositories

- One agent session per module (matrix job), joined by the verify job.
- Agent, skills and scripts in one versioned central repository; teams add skills.
- An organisation ruleset requires that workflow everywhere, so authors cannot change it.

## 9. For a production version

- No model key in repositories: a gateway that accepts GitHub OIDC tokens only from the
  central workflow (`job_workflow_ref`), with limits and logs.
- A GitHub App token for the agent's commits, with a quick check instead of `[skip ci]`.
- CODEOWNERS with required review for `.github/` and `.claude/`.
- Actions and Claude Code pinned by SHA, updated by Dependabot or Renovate.
- Pester tests for the PowerShell modules in CI.
- A short history of earlier runs in the comment.
