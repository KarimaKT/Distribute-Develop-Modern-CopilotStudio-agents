# Security Policy

## Reporting a vulnerability

This is a community toolkit of PowerShell scripts for Copilot Studio agent ALM. If you discover a
security issue in the scripts (for example, unsafe handling of credentials, tokens, or solution
content), please report it privately rather than opening a public issue:

1. Open a [GitHub Security Advisory](https://github.com/KarimaKT/Distribute-Develop-Modern-CopilotStudio-agents/security/advisories/new) on this repository, **or**
2. Contact the maintainer directly via GitHub.

Please include steps to reproduce, the affected script, and the impact. You will get an
acknowledgement within a reasonable time, and a fix or mitigation will be coordinated before any
public disclosure.

## Scope and handling of secrets

These scripts use your existing `pac` and `az` CLI sessions and acquire short-lived Dataverse
access tokens at runtime. They do **not** store, log, or transmit credentials. When reporting an
issue, never paste real tokens, connection strings, or environment URLs into a public issue.

## Microsoft product issues

Bugs in the underlying Power Platform CLI (`pac`) or Copilot Studio are **not** in scope for this
repository. Report those through official Microsoft channels (e.g. the
[pac CLI repository](https://github.com/microsoft/powerplatform-build-tools)).
