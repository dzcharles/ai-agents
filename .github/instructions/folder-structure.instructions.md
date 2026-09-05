---
applyTo: '**'
description: 'Comprehensive guide to the folder structure for managing the created output files'
---

# Folder Structure Guide

The files and folders below represent the recommended structure for managing the created output files.
The folder structure are mandatory for organizing and managing the created output files effectively, unless stated als optionally.
Extra files can be created as needed inside the folder structure to accommodate additional requirements or artifacts, but the core structure should remain intact and should not be altered.

## Requests folder

Anything gets tracked as a **work item**. You'll hear it
called a request, project, issue, or problem; treat all of those the same
way, just record which word was used in the item's `type`.

Root folder: `./requests/` - if you don't see a `requests/` folder, create it.

```
./requests/
  _index.md                        # table: slug | type | title | status | last updated
  <slug>/
    request.md                     # the original ask, verbatim, plus any clarifications
    plan.md                        # Planner's task list
    status.md                      # current stage + per-task status + review round count
    review.md                      # Reviewer's latest findings (overwrite each round)
    artifacts.md                   # paths to the real files specialists produced, with a one-line note each
    README.md                      # Doc Writer's final output, once everything passes
```

A `SessionStart` hook injects the contents of `./requests/_index.md` at the start of
every chat session, so you already have the current list of work items
without needing to go read the file first.

## Script folder

Any script that is created needs to be placed inside the `./scripts/` folder and follow the structure outlined below.

Root folder: `./scripts/` (for all scripts) - if you don't see a `scripts/` folder, create it.

```
./scripts/
  _index.md                        # table: <script/module> | language | title | description | last updated
  modules/                      
    <module1>/
    <module2>/
  script1.ps1
  script2.ps1
  script3.py
```

A `SessionStart` hook injects the contents of `./scripts/_index.md` at the start of
every chat session, so you already have the current scripts
without needing to go read the file first.

‼️ If the last update time of a script is older then 30 days, ask the responsible agent to review it and update it if necessary.

## Bicep/Azure Pipeline structure

Root folder `./azure-iac/slug-of-request/` (where `slug-of-request` is a unique identifier for the request). If you don't see a `azure-iac/` folder, create it. 

```
azure-iac/
├── modules/           # Reusable components
├── parameters/        # Environment-specific parameters
├── pipelines/         # Empty folder for CI/CD pipelines (out of your scope)
└── docs/              # Empty documentation folder (out of your scope)
```

## Docker and Docker Compose structure
Root folder: `./docker-output/slug-of-request/` (where `slug-of-request` is a unique identifier for the request). If you don't see a `docker-output/` folder, create it.
```
./docker-output/
  _index.md                        # table: slug | type | title | status | last updated
  <slug>/
    Dockerfile                     # The Dockerfile for the project
    build.sh                       # Script to build the Docker image (extension: .sh for bash, .ps1 for PowerShell, etc.)
    run.sh                         # Script to run the Docker container (extension: .sh for bash, .ps1 for PowerShell, etc.)
    upload.sh                      # Script to upload the Docker image to a registry (extension: .sh for bash, .ps1 for PowerShell, etc.)
    docker-compose.yml             # Docker Compose file for the project
    README.md                      # Instructions and documentation for the Docker setup
```
