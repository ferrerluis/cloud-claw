---
name: para-memory-drive
description: Navigate and maintain a Google Drive-hosted PARA memory workspace. Use when Codex needs to find cross-project or cross-area context in Drive, create or classify durable knowledge artifacts, update CONTEXT.md, INDEX.md, TODOS.md, or project specs, manage relationships, capture an Inbox item, set up a PARA Drive workspace, migrate a node, or archive work. Use this instead of para-memory for the Drive-backed workspace; do not use it for routine code, tests, fixtures, generated output, caches, dependencies, temporary files, or local checkout edits.
---

# PARA Memory – Drive

Maintain a Google Drive PARA workspace as a curated memory and navigation layer over its source artifacts. Use this skill, rather than para-memory, for Drive-backed PARA work.

## Drive workflow

Use Google Drive as the source of truth for PARA folders and Markdown files.

1. Ground each folder or file before acting. Reuse only an observed Drive URL or ID; never infer one.
2. Discover folders with Drive search and inspect their exact titles and parent IDs. Use list-folder for direct children and recurse only through relevant folders.
3. Fetch Markdown before relying on or editing it. Search indexes, aliases, and CONTEXT.md files before broad traversal or duplicate creation.
4. For Markdown writes, re-fetch immediately before editing, make the narrow change, upload or update the raw file in place, then read it back. Preserve sharing state and parents.
   If the connector warns that a raw-file replacement risks overwriting concurrent shared changes, do not bypass it: re-fetch, show the exact minimal update, and proceed only with fresh explicit user confirmation.
5. For moves, inspect parent IDs, add only the verified destination parent, remove only the verified source parent, and verify the destination listing or metadata.

Drive search is keyword-based, not native semantic search. For meaning-based research, use targeted keyword search followed by bounded content fetches.

## Orient

1. Locate the Drive root containing INDEX.md and the numbered Inbox and PARA folders.
2. Read root INDEX.md.
3. Read the smallest relevant node's CONTEXT.md and INDEX.md.
4. Read the nearest AGENTS.md available for the root or project before acting.
5. Treat original code, configuration, contracts, and source documents as authoritative. Treat CONTEXT.md as reviewed summary and INDEX.md as routing aid.

## Set up a PARA Drive workspace

When the user says to set up a PARA workspace, complete this discovery before normal maintenance.

1. If the user supplied a Drive folder URL, inspect that folder. Otherwise search separately for the five required category-folder names, keep exact folder-title matches, and group them by shared parent ID.
2. If multiple candidate roots remain, list their observed Drive URLs and ask the user to select one. Do not modify a candidate.
3. If no candidate exists, create a folder named workspace in My Drive root; create 00_INBOX, 01_PROJECTS, 02_AREAS, 03_RESOURCES, and 04_ARCHIVES; then create the root and category INDEX.md files. Put this marker directly below the root-index title:

   <!-- para-memory-drive: schema-version=1 -->

   Verify every created folder and file through Drive readback and report the observed root URL.
4. If one candidate exists, fetch its root INDEX.md and verify its direct category folders.
   - If it contains the marker, report the existing skill-created workspace and exit without changes.
   - If it lacks the marker, inspect it read-only and return a concrete conformance proposal. Include missing categories/indexes, stale index links, malformed node basics, and every project's missing TODOS.md, specs folder, or specs/INDEX.md. Do not apply this proposal unless the user separately authorizes it.

## Classify

- Put unclassified authorized captures in 00_INBOX.
- Put finite efforts with an outcome and definition of done in 01_PROJECTS.
- Put ongoing people, responsibilities, businesses, and standards in 02_AREAS.
- Put reusable reference without an active obligation in 03_RESOURCES.
- Put inactive whole nodes in 04_ARCHIVES.

Keep project-specific research and assets with their project until they have repeated cross-project value.

## Maintain CONTEXT.md

Give every project, area, and resource a CONTEXT.md with YAML frontmatter followed by readable Markdown. Use these common fields:

    ---
    title: Human-readable title
    type: project
    status: active
    aliases: []
    relationships:
      areas: []
      projects: []
      resources: []
    last_reviewed: YYYY-MM-DD
    ---

Use only active, paused, or archived for status.

For a project, include Summary, Outcome, Definition of Done, Current State, Next Actions, Decisions, and Canonical Sources.

Repository-backed projects may add:

    repositories:
      - name: repository-name
        role: primary
        remote: https://github.com/owner/repository
        checkout: ~/repos/repository
        default_branch: main

Omit repositories when a project has no repository. A project may list multiple repositories, and multiple projects may refer to the same repository.

For an area, include Summary, Ongoing Responsibilities, Standards and Constraints, Current Focus, and Canonical Sources. For a resource, include Summary, When to Use, and Canonical Sources.

Store project-to-area relationships only in the project's relationships.areas list, using paths relative to the project. Do not duplicate project lists in an Area context or index; search 01_PROJECTS for the Area path when answering relationship questions.

Update last_reviewed only after verifying the context against current sources.

## Work with repository-backed projects

1. Read the project's repositories entries before source-code work.
2. Expand the declared checkout, verify it exists, and confirm its Git remote matches the declared remote.
3. Read the checkout's nearest AGENTS.md and canonical repository documentation before changing source.
4. Treat the checkout as authoritative for code, configuration, contracts, tests, and repository-local documentation. Treat the Drive node as authoritative for cross-project context and durable memory.
5. If a checkout is missing and source work is authorized, clone the declared remote outside the Drive workspace. Otherwise report the missing checkout instead of creating a duplicate.
6. Never place .git directories, dependencies, build output, caches, or symlinks to checkout trees in PARA folders.
7. Index a repository as one navigable collection when useful; do not index routine internals.

## Maintain INDEX.md

Give the root, every PARA category, every PARA node, and the specs collection an INDEX.md. Use a concise table:

    | Path | Kind | Description |
    |---|---|---|
    | [relative/path](relative/path) | Research | Explain what an agent will find and why it matters. |

1. List CONTEXT.md first in every node index.
2. Index plans, research, decisions, deliverables, key assets, canonical guidance, and navigable child collections.
3. Do not index routine source code, tests, fixtures, generated output, caches, dependencies, or temporary files.
4. After creating or materially relocating a knowledge artifact, update exactly one nearest ancestor index entry with a useful relative link.
5. When creating a child collection with an index, add the collection to its parent's index.
6. Do not propagate leaf artifacts to category or root indexes.
7. Repair stale index entries in the same authorized move or deletion.
8. Do not list INDEX.md itself.

Read an index again immediately before editing it. Change only the relevant rows and preserve unexplained concurrent changes.

## Maintain TODOS.md and specs

Every project must contain a TODOS.md and a specs folder with specs/INDEX.md. Create all three with every project and add TODOS.md and specs exactly once to the project index.

Use TODOS.md as a durable backlog, never as implementation authorization. Its entries are optional. Search the project and its indexes before adding an item; keep stable numbered headings and preserve completed or superseded entries. Keep a top Index current whenever an item's title, status, dependency, or canonical design changes. Use Proposed, Planned, In progress, Blocked, Completed YYYY-MM-DD, or Superseded.

Store project-specific canonical designs in specs and index them from specs/INDEX.md. Link designs from TODO items instead of duplicating them. Record completion date and acceptance evidence before marking a TODO complete.

Use this TODOS.md shape:

    # Project TODOs

    This is a durable backlog, not authorization to implement or change production data.

    ## Index

    | # | Title | Status | Dependencies | Canonical design |
    |---|---|---|---|---|
    | 1 | Short title | Proposed | — | [Design](specs/features/example.md) |

    ## 1. Short title — proposed

    Canonical design: [Design](specs/features/example.md).

    Why:

    Required behavior:

    Open decisions:

    Dependencies:

    Acceptance evidence:

## Capture Inbox items

When an authorized write has genuinely uncertain classification:

1. Create 00_INBOX/YYYY-MM-DD--short-slug.md.
2. Record the source, durable content, uncertainty, and likely destinations.
3. Add it to 00_INBOX/INDEX.md.

Do not use Inbox as a general backlog or impose automatic aging.

## Create, move, and archive nodes

When creating a project, create CONTEXT.md, INDEX.md, TODOS.md, specs, and specs/INDEX.md together, then register its CONTEXT.md in the Projects index. When creating an area or resource, create CONTEXT.md and INDEX.md together and register its context in the parent category index.

Before moving a node, inspect active path assumptions and Drive parent IDs; preserve the internal layout unless splitting is authorized; move once; repair operational references and inbound index links; and verify direct contents after the move.

When archiving, move the whole node to the matching 04_ARCHIVES collection, set status to archived, retain its context and index, and repair inbound links.

## Write durable memory only

Write stable facts, decisions, outcomes, constraints, relationships, next actions, and source pointers. Do not write chat transcripts, speculative conclusions, routine command output, generated artifacts, or duplicated source content.

Do not modify memory during a read-only answer unless the user authorizes workspace changes or the requested implementation naturally includes documentation maintenance. Never copy secrets, credentials, private keys, Terraform state, or token-bearing URLs into PARA files or indexes.
