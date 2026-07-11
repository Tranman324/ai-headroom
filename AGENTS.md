APM_RULES {

## Scope Discipline

- Implement only the macOS native application behavior supplied in the Task Prompt. Do not add iOS targets, web views, servers, network listeners, account switching, notifications, tunnels, distribution infrastructure, or unrelated product features.
- Preserve established module boundaries and shared contracts. When a required contract change affects another module, make the smallest compatible change and report the impact explicitly.
- Use Apple platform frameworks and the standard library by default. Do not add a third-party runtime dependency unless the Task Prompt explicitly requires it.

## Swift And Architecture

- Keep UI-observable mutation on the main actor and isolate concurrent polling, filesystem, credential, and network work with clear Swift concurrency boundaries. Avoid detached work that cannot be cancelled or tested.
- Put provider access, filesystems, clocks, connectivity, lifecycle events, and login registration behind narrow injectable interfaces when touching those concerns. Production and deterministic test implementations must conform to the same behavior contract.
- Decode and encode structured data with structured APIs such as `Codable` or `JSONSerialization`; do not parse credential, API, settings, or history JSON with ad hoc string manipulation.
- Treat unknown additive JSON fields as compatible while failing missing required fields locally and explicitly. One malformed provider or history record must not corrupt healthy state outside its scope.

## Security And Privacy

- Never print, log, persist, display, snapshot, or include in test evidence any access token, refresh token, authorization header, or complete credential document. Sanitize errors at the boundary where sensitive values are available.
- Read credentials only from their canonical local source for the active operation. Do not introduce credential caches, copies, fixtures containing real values, or shell-based Keychain access.
- Preserve restrictive permissions on sensitive directories and files. Tests that touch persistence or atomic replacement must assert permissions as well as content.
- Use fake credentials and injectable transports/filesystems in automated tests. Live validation may report provider and meter presence or sanitized utilization values, never authentication material.

## Validation

- Run the narrowest relevant build and tests while iterating, then run the complete affected target suite before reporting completion. Do not weaken assertions, skip failing tests, or replace production paths with test-only shortcuts to obtain a pass.
- Add focused regression coverage for changed decoding, calculations, persistence, lifecycle, or state-transition behavior. Include failure and boundary cases, not only the happy path.
- For UI changes, exercise the actual interaction and inspect screenshots at the required fixed dimensions. Check text clipping, overlap, material rendering, state colors, navigation, and control hit behavior rather than relying solely on compilation or view construction.
- Verify that generated logs, history fixtures, screenshots, and reports are free of secrets before treating validation evidence as shareable.

## QA Gates

- Trivial, contained changes may use a lightweight gate: relevant tests or build, direct inspection of the changed behavior, and a concise evidence note.
- Credential handling, security/privacy, API or persistence schemas, lifecycle/recovery behavior, multi-module integration, generated project configuration, and larger changes require a full two-critic gate after implementation validation.
- The Test Gate Critic checks that proof exercises the real work trajectory, covers success and failure paths appropriate to the change, and has not been weakened to manufacture a pass.
- The Adversarial Change Critic treats implementation reports and narratives as untrusted, checks whether the claimed invariant is structurally enforced, and considers a practical negative control or deliberate sabotage test when feasible.
- Use compact QA reporting for small accepted work. Provide fuller commands, evidence paths, rejected findings, residual risks, and recovery details for cross-boundary, gate-critical, rejected, or autonomous-recovery work.
- These gates cover execution failures such as stalls, weak or fake-green reports, ambiguous evidence, rejection loops, and abandoned output. They do not repair missing requirements, product gaps, requirement misreads, or promises omitted from the assigned work; escalate those instead of silently inventing scope.

## Change Hygiene

- Keep edits scoped to the assigned deliverable and preserve unrelated workspace changes. Do not reformat or refactor unrelated files.
- Use succinct comments only where concurrency, security, calculation, or recovery logic would otherwise be difficult to audit.
- Report validation commands and outcomes, evidence paths, unresolved risks, and any required User action such as a macOS credential prompt.

## Version Control

- Use one `codex/<short-description>` feature branch per assigned Task, created from `main` unless the Task Prompt specifies another reviewed base.
- Write sentence-style imperative commit messages, for example `Create macOS project scaffold and shared models`.
- Do not push branches or commits to a remote unless the User explicitly requests it.

} //APM_RULES
