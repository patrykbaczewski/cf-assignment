---
name: tf-review-findings
description: Report what a reviewer should know about Terraform module code (security, reliability, correctness), with evidence and severity, without changing the code. Use while reading module code for tests and before writing the final result.
---

# Report findings to reviewers

You help people trust this code. When you see something a reviewer should know, report
it. You never change infrastructure code: what to do about a finding is a decision for
people.

## Checklist

Look for these while you read a module. Report only what you actually see.

Each item has a fixed severity. Use it, so the same problem gets the same severity in
every run. Do not raise or lower it because of other settings ("public access is also
on, which makes this worse"): describe that in `detail` instead.

**Security**

| What you see | Severity |
|---|---|
| Weak transport: HTTPS not enforced, TLS below 1.2, FTPS other than `Disabled` or `FtpsOnly` (plain FTP allowed) | `high` |
| A secret in an output without `sensitive = true` | `high` |
| Public network access on by default (`public_network_access_enabled`, `public_network_enabled` default `true`) | `medium` |
| Network rules with `default_action = "Allow"` | `medium` |
| An Owner role (for example `Storage Blob Data Owner`), or a role that may be broader than needed. When you are not sure a smaller role works, keep `medium` and say "verify against the Azure documentation" | `medium` |
| Code that runs programs during plan: `data "external"`, `local-exec` | `medium` |

**Reliability and correctness**

| What you see | Severity |
|---|---|
| No diagnostic logs on a service that holds data or secrets | `medium` |
| A private endpoint without a private DNS zone group | `medium` |
| Delete protection or retention turned off | `medium` |
| Diagnostic logs that leave out some categories | `low` |
| An input with known limits but no `validation` (names, ranges, allowed values) | `low` |
| A result that changes on every run (for example a revision read during plan) | `low` |
| A value fixed in code that callers probably need to change (SKU, size, retention) | `info` |

## Rules

1. **Evidence.** Every finding names the file and the line where you saw it. Read the
   line before you cite it.
2. **No guessing about Azure.** If you are not sure how Azure behaves (allowed ranges,
   limits, defaults), say "verify against the Azure documentation" instead of stating a
   number.
3. **`introduced_by_change`** is `true` only when the diff of this change added or
   changed the problem. Existing problems are still worth reporting, with `false`.
4. **At most 10 findings per module.** Most important first. No duplicates.
5. **Recommendation, not a fix.** Say what a person could change. Do not edit the module.
6. **`suggested_test`** is either `null` or one complete `run` block that fails on the
   current code (see the `tf-test-authoring` skill).

## Severity

For a finding that matches no checklist item, choose with this table:

| Severity | Use when |
|---|---|
| `high` | Likely security exposure or outage in a normal deployment |
| `medium` | A real risk under some conditions or configurations |
| `low` | A weakness worth fixing, little direct risk |
| `info` | Worth knowing, no action needed |

## Category

`security`, `reliability`, `correctness` or `maintainability`.
