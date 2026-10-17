---
name: tf-test-run
description: Run a module's terraform tests in the sandbox, fix mistakes in the tests, and tell test mistakes apart from defects in the module. Use after writing or changing a .tftest.hcl file, and before reporting any test result.
allowed-tools: Bash(pwsh -File .github/scripts/Invoke-TerraformTest.ps1 *)
---

# Run Terraform tests

## How to run

```sh
pwsh -File .github/scripts/Invoke-TerraformTest.ps1 -ModulePath modules/<name>
```

This is the only allowed way. Do not run `terraform` or any other command: the module
code is untrusted and only runs inside this script's sandbox.

The script prints a status:

| Status | Meaning |
|---|---|
| `passed` | Every run passed and the test files are formatted |
| `failed` | At least one run failed (see the runs marked `fail`) |
| `error` | Terraform could not init or parse the files; read the error |
| `no_tests` | No tests found |

`Formatting: NOT OK` lists files that are not formatted like `terraform fmt`. Fix the
spacing by hand; you cannot run `terraform fmt`.

A failed assertion does not stop the file, but an error does (for example "Unknown
condition value" or an invalid input): the later runs in that file are reported as
`skip`. Skipped runs were not checked, so they are not passing. Fix the error and run
again.

If the output shows `TERRAFORM CRASH` or `panic:`, Terraform itself failed, not your
test or the module. Known case: an assertion that compares whole lists (for example with
`sort()`) crashes when it fails. Write the check another way (`length()` plus
`contains()`), and mention the crash in `limitations`.

## Fix loop: at most 3 attempts per module

For every failing run, decide which case it is:

**The test is wrong.** For example: wrong attribute path, an assertion on a value unknown
at plan time, an input in the wrong format, a wrong guess about how the mock behaves.
Fix the test and run again.

**The module is wrong.** The test checks something the module promises (a variable
description, a validation, a naming convention, the security baseline) and the code does
not do it. Then:

1. Remove that run from the file.
2. Report a finding with the run as `suggested_test` (skill `tf-review-findings`).
3. Run the tests again without it.

Never make a test pass by weakening or deleting an assertion that checks a real
requirement. A green test that hides a defect is worse than no test.

After 3 attempts, remove the runs that still fail, record each in `limitations` or as a
finding, and continue.

## Before you report

The last thing you do for a module, after your last edit, is run its tests. Its status
is the `final_test_status` you report. Do not report a status you did not see.
