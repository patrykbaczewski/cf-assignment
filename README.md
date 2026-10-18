# Terraform Platform Base

A small Terraform repository for a data platform on Azure: networking, storage, secrets, monitoring, data integration, analytics and a function app.

## Layout

```text
modules/            Reusable modules. Each has main.tf, variables.tf, outputs.tf and versions.tf.
  <module>/tests/   Tests for a module (terraform test, *.tftest.hcl).
stacks/
  data-platform/    The stack that uses the modules. One set of variables per environment in envs/.
.claude/            The Terraform test agent and its skills.
.github/            The pull request workflow and its PowerShell scripts.
```

## Terraform test agent

Every pull request that changes a module is checked by an AI agent (Claude Code). It
adds or updates the module's `terraform test` files, the workflow runs them, commits the
verified tests to the pull request and posts the results and the agent's findings as one
comment. The agent never changes infrastructure code: it reports, people decide. How it
works, why it is built this way and its limits are in [SOLUTION.md](SOLUTION.md).

## Requirements

- Terraform 1.9 or newer
- Internet access to download providers
- No Azure subscription or credentials

## Run the tests of a module

The tests use a mocked `azurerm` provider, so they need no credentials.

The recommended way is the sandbox script (needs PowerShell 7.4 and Docker). Module code
can start local programs while it is tested (the function app runs a shell script through
`data "external"`), so the script runs the tests in a container without network access,
on a copy of the module:

```sh
pwsh -File .github/scripts/Invoke-TerraformTest.ps1 -ModulePath modules/storage-account
```

For a module that runs no local programs, plain Terraform works as well:

```sh
cd modules/storage-account
terraform init -backend=false
terraform test
```

## Check the stack

```sh
cd stacks/data-platform
terraform init -backend=false
terraform fmt -check -recursive ../..
terraform validate
```

The stack has no backend configured. A real deployment would need one, and credentials for it.

## Conventions

- Resource files in a stack and modules use `main.tf`, `variables.tf`, `outputs.tf` and `versions.tf`.
- Use `for_each` rather than `count` for repeated resources.
- Environments are `dev`, `uat` and `prod`.
- Format code with `terraform fmt -recursive` before committing.
