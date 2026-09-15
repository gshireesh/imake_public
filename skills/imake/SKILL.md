---
name: imake
description: Write and edit imake.yml task-runner configs (imake — the k9s-style task runner / Makefile TUI). Use when the user asks to create, update, or debug an imake.yml/imake.yaml, wire up dev tasks, link subproject imake files, or run task groups with imake.
---

# Writing imake.yml configs

imake runs named groups of tasks concurrently in a TUI (`imake <group>`),
with per-task ptys and real terminal emulation. Config lives in
`imake.yml` (or `imake.yaml`) at the project root.

## Shape

Start new files with the schema line so editors complete and validate
fields:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/gshireesh/imake_public/main/imake.schema.json
```

Top level = group names. Each group maps task names to either a plain
command string or an object:

```yaml
dev:
  ui: pnpm dev                         # plain string task
  backend:
    command: go run ./cmd/main.go      # object task, full lifecycle
    dir: backend                       # cwd, relative to this file
    env: {PORT: "8080"}                # extra environment for every phase
    before: echo starting...           # runs first
    timeout: 10s                       # duration (10s, 500ms, 2m) or bare ms
    on_success: echo ok                # exactly one of these three
    on_error: echo failed              #   runs based on the result
    on_timeout: echo too slow
    after: echo done                   # always runs last
    restart_policy: on-failure         # always | on-failure | never (default)
    keep_shell: true                   # drop into $SHELL when done
    manual: true                       # wait for the user to press r
    prompt: drops the db!              # are-you-sure dialog; true or a message
    passthrough: true                  # for TUIs needing esc & / (claude, vim)
    depends_on: [db]                   # start after these finish OK
    section: infra                     # sidebar sub-heading (display only)
  release:
    command:                           # a LIST runs as one && chain
      - go vet ./...
      - go build ./...
```

Field notes:

- **Prefer `dir:` over `cd X && ...`** — cleaner, and the command stays
  portable. When chaining inline anyway, **join with `&&`, never `&`**
  (`&` backgrounds the first command — the classic config mistake). A
  command *list* sidesteps the issue entirely: imake joins with `&&`.
- Each task runs in its own shell (`sh -c` on unix, `cmd /C` on
  Windows).
- `timeout` accepts durations (`10s`, `500ms`, `2m`) or bare
  milliseconds. `before`/`after`/`on_*` accept strings or lists too.
- `depends_on` targets must exist in the same (resolved) group; cycles
  and unknown names are rejected at load. Dependent tasks start only
  after every dependency succeeds. A manual dependent still needs `r`.
- `manual: true` for anything destructive, one-shot, or on-demand
  (migrations, deploys, seeds). For truly dangerous ones use `prompt:`
  — `true`, or a string that is both the switch and the dialog message.
- `passthrough: true` when the task hosts a full TUI that needs `esc`
  and `/` itself; users reach imake via the `ctrl+t` prefix.
- `section:` only affects sidebar layout (collapsible sub-heading).
  Slash-separated paths nest: `section: backend/messaging` renders as a
  `messaging` heading indented under `backend`; folding a parent hides
  the subtree, and header-wide start/stop covers nested sub-sections.
  A merge entry may set `section:` to rebase the folded tasks under a
  sub-section of the target group (the tasks' own sections nest beneath
  it): `merge: {dev: [{path: ./x, group: dev, section: messaging}]}`.
  `group:` is a deprecated alias for it; don't write it in new configs.
- After hand-editing a config, `imake migrate --check` tells you whether
  it matches the canonical format; `imake migrate` fixes it in place
  without changing behavior (it verifies every task before writing).

## Macros

A `macros:` top-level block defines parameterized task templates; a
group entry with `macro:` stamps them out. `{{param}}` substitutes in
every scalar — task names included — and all field sugar works inside
templates. Use a macro whenever the same task shape repeats with only a
name or path changing.

```yaml
macros:
  service:
    params: {svc: null, repo: ../storm}   # null = required, else default
    tasks:
      migrate_{{svc}}:
        command: make migrate SVC={{svc}}
        dir: '{{repo}}'                   # quote values that START with {{
        manual: true
        section: svc_{{svc}}
      run_{{svc}}:
        command: make run SVC={{svc}}
        dir: '{{repo}}'
        depends_on: ['migrate_{{svc}}']   # quote {{ }} inside [flow] lists
        section: svc_{{svc}}

dev:
  services:
    macro: service
    foreach:                 # one expansion per item
      - policycheck          # bare scalar -> first declared param (svc)
      - bridge
      - {svc: analysis, repo: ../storm.pa}
  one-off:
    macro: service
    with: {svc: flags}       # single expansion (with OR foreach, not both)
```

Rules: macros are local to the file that defines them (included files
expand their own); placeholders must be declared params — checked at
load even for unused macros; generated names colliding with hand-written
tasks (or each other) are load errors; generated tasks are read-only in
the TUI's edit form — edit the macro or its `foreach` entry instead. Deleting one (ctrl+d) removes the whole `foreach`
item that generated it, sibling tasks included. In
the TUI, `N` opens "new from macro": fill the params, then either
persist (appends a `foreach` item) or run once without touching the
file.

## Linking subprojects

`include` **adds** other projects' groups; `merge` **folds** them into
your own groups. Included/merged tasks run with their subproject
directory as cwd — write their commands as if local to that project.

```yaml
include:
  discover:              # -> top-level group "discover"
    path: ./discover
    group: dev           # just that group from discover/imake.yml
  backend: ./backend     # string form: ALL groups -> backend:dev, backend:test

merge:
  dev:                   # my dev group gains...
    - path: ./discover
      group: dev         # ...discover's dev (group is always explicit)
    - path: ../storm
      group: w:jobs      # ...a deep group via its namespaced name

dev:
  proxy: caddy run
```

Rules: an `include` alias may not clash with a group defined in the
same file (use `merge:` for that); task-name collisions in a merged
group are load errors; includes nest, diamonds are fine, true cycles
are rejected. Namespaced groups work anywhere a group name does:
`imake backend:dev`.

## CLI quick reference

```
imake              groups table (k9s-style); enter opens, esc/g backs out
imake <group>      open straight into a group
imake -n [group]   open the new-task form (creates imake.yml if missing)
imake -m [group]   everything manual — start each task with r
imake -p <group>   plain prefixed output, no TUI (CI-friendly); runs auto
                   tasks only — add -a to include manual: tasks
imake .            browse Makefile targets
imake migrate      rewrite imake.yml into the canonical format (deprecated
                   keys, dir:, durations, key order); --dry-run, --check
imake ctl <cmd>    drive a RUNNING imake from this shell (see below)
```

## Driving a running imake

When someone already has `imake <group>` open in another terminal, do
not start a second one — attach to theirs. `imake ctl` talks to the
running TUI over loopback and finds the session by working directory,
so inside the project no session id is needed.

```
imake ctl status              every open task: state, phase, pid, ports
imake ctl logs <task> -n 200  that task's output, ANSI stripped
imake ctl logs <task> -f      follow it live
imake ctl restart <task>      exactly what pressing r does
imake ctl start|stop <task>   start a stopped/manual task, or stop one
imake ctl reload              re-read imake.yml after editing it
imake ctl wait <task>         block until it settles; exit 1 if it failed
imake ctl ls                  list running sessions
```

**The loop to use after changing code.** `wait` is the important part:
it blocks until the task stops running and sets the exit status, so
there is no sleeping and no guessing.

```sh
imake ctl restart api          # relaunch the task that covers your change
imake ctl wait api --timeout 60s || imake ctl logs api -n 80
```

For a long-running server that never settles, skip `wait` and read the
log directly after giving it a moment:

```sh
imake ctl restart api && sleep 2 && imake ctl logs api -n 40
```

Notes that matter in practice:

- Only groups the user has actually **entered** in the TUI are visible.
  `imake ctl status` returning nothing means they are sitting on the
  groups table, not that something broke.
- Address a task as `<task>`, or `<group>:<task>` when two open groups
  use the same name.
- Add `--json` to any command for structured output.
- A `prompt: true` task will not start from `ctl` — it queues the
  are-you-sure dialog for the person at the keyboard. That is
  deliberate; tell them to confirm it.
- `restart` clears the task's scrollback, so read logs *after* the
  restart, not before.
- Editing `imake.yml` does not take effect until `imake ctl reload`.

## Recipes

Dev stack with a database gate:

```yaml
dev:
  db:
    command: docker compose up postgres
    section: infra
  migrate:
    command: make migrate
    depends_on: [db]
  api:
    command: go run ./cmd/api
    depends_on: [migrate]
  ui: {command: pnpm dev, dir: web}
```

Dangerous one-shot:

```yaml
ops:
  reset-db:
    command: make db-reset
    manual: true
    prompt: DROPS and recreates the local database
```

Task ending in an inspectable shell:

```yaml
build:
  release:
    command: make dist
    keep_shell: true     # attach to poke at the artifacts afterwards
```
