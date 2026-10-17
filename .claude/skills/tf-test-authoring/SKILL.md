---
name: tf-test-authoring
description: Write or update `terraform test` files (.tftest.hcl) for modules in this repository, with a mocked azurerm provider. Use when adding tests, improving coverage or updating tests after a module change.
---

# Write Terraform tests

Tests live in `modules/<name>/tests/`. Prefer one file, `main.tftest.hcl`. Add another
file only for a clearly separate topic. When a file exists, edit it: keep passing runs,
do not add a second run for the same behaviour.

A complete, tested example is in [examples.md](examples.md). Read it before writing the
first test of a session.

## Rules

Each rule comes from a real failure. Follow all of them.

1. **Mock the provider.** Start the file with `mock_provider "azurerm" {}`. Never use real
   credentials, a `provider` block with secrets, or anything that needs the network.
2. **Override every `data "external"`** (and any other data source that runs a program)
   with a file-level `override_data` block. Without it the program runs during the test.
3. **Use realistic inputs.** The mocked provider still checks formats: storage account
   names (3-24 lowercase letters and digits), UUIDs for tenant and principal IDs, full
   Azure resource IDs for `*_id` inputs, for example
   `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest001`.
4. **Use `command = plan`** unless you need values that only exist after apply.
5. **Do not assert on values unknown at plan time** (`id`, `principal_id`, endpoints,
   anything computed by Azure). The run fails with "Unknown condition value". Either:
   - add `override_resource { target = ..., override_during = plan, values = { id = "..." } }`
     to the run, or
   - use `command = apply` and give the resource a valid ID through
     `mock_resource "<type>" { defaults = { id = "..." } }` inside `mock_provider`.
     Without it the mock invents an ID like `zdbxtco0`, and resources that take that ID
     as input fail.
6. **One behaviour per `run`.** Name it after the behaviour in snake_case, for example
   `rejects_unknown_sku`, `creates_one_subnet_per_key`.
7. **Every `run` checks something**: at least one `assert`, or `expect_failures`.
8. **Rejected values** use `expect_failures = [var.<name>]` with the bad value in the
   run's own `variables` block.
9. **`error_message` states the requirement and why it matters**, not the condition:
   "FTP deployment must be off: it sends credentials in plain text."
10. **Test what the module promises, not what the code happens to say.** Base each
    assertion on a variable description, a validation, a naming convention or the
    security baseline. A test that only repeats the code proves nothing. In particular:
    - Do not write runs that only check that an input reaches an attribute of the same
      name unchanged (`name`, `location`, `resource_group_name`, `tags`). Test it only
      when the module changes the value (a prefix, a merge, a lookup).
    - A condition checks one exact thing. Do not soften it with `try()`, `|| ... == null`
      or similar so that it passes in more cases.
11. **Format like `terraform fmt`**: two-space indent, `=` aligned within a block.

## A test that exposes a defect

If the code does not do what it promises, do not commit a failing test. Report a
finding (skill `tf-review-findings`) and put the test in its `suggested_test` field:
one complete `run "..." { ... }` block, valid HCL, that fails on the current code and
passes once the code is fixed. Nothing else in that field.
