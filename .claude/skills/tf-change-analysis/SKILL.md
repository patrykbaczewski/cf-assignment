---
name: tf-change-analysis
description: Decide which Terraform modules a change affects and whether their tests must be added, updated or left alone. Use at the start of any test task on modules/, before writing tests.
---

# Analyze a Terraform change

The goal is a decision per module and a short list of behaviours to test. Do not write
tests in this step.

## Inputs

- The modules to look at (`modules/<name>`). In CI the task lists them.
- The diff of the change. In CI the task gives a file with the diff. In an interactive
  session, use `git diff origin/main...HEAD -- modules/<name>`.
- A module with no diff (for example "add missing tests") is analyzed as a whole.

## Steps for each module

1. Read the diff hunks of the module.
2. Read the whole module, not only the changed lines: `main.tf`, `variables.tf`,
   `outputs.tf`, `versions.tf`, and every file in `tests/`. A changed line often matters
   because of code around it.
3. Classify the change with the table below. A change can match several rows.
4. Write down the behaviours to test, one per line, in plain words. Each behaviour must
   come from something you read: a variable description, a validation, a naming pattern,
   a security setting, a `for_each`. Note where you read it (`file:line`).

| The change | Decision | What to test |
|---|---|---|
| New or changed `validation` on a variable | `tests_added` / `tests_updated` | One accepted value and at least one rejected value (`expect_failures`) |
| New resource, `for_each`, `count` or `dynamic` block | `tests_added` / `tests_updated` | Number of instances, their keys, and the attributes that matter |
| Changed security setting (public access, TLS, FTPS, HTTPS, network rules, identity, role) | `tests_added` / `tests_updated` | The exact value of the setting |
| Changed name pattern or `locals` | `tests_added` / `tests_updated` | The resulting names |
| New or changed variable without validation | `tests_added` / `tests_updated` | That the value reaches the right attribute |
| Behaviour change that breaks an existing test | `tests_updated` | Update that test, and say in `reason` which behaviour changed |
| Only comments, descriptions or formatting | `no_tests_needed` | Nothing; existing tests still run |
| Only test files changed (by a person) | `no_tests_needed` | Nothing new; run the tests and report problems |
| Module has no tests at all | `tests_added` | The main promises of the module (see below) |
| You cannot work on the module (for example it does not parse) | `skipped` | Nothing; explain why in `reason` |

## A module with no tests

Cover what the module promises to its users, most important first:

1. Security settings that are fixed in code or have a default.
2. Every variable validation (accepted and rejected values).
3. Every `for_each` / `count` / `dynamic` block (with entries and empty).
4. Name patterns the module builds.
5. Wiring between resources (one resource uses another's ID or name).

Five to ten well-chosen `run` blocks are better than many shallow ones.

## While you read

Anything a reviewer should know (a risky default, a missing validation, a script that
runs during plan) is a finding. Use the `tf-review-findings` skill for it. Do not change
the module.
