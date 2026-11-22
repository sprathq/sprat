# Contributing

Issues are welcome: bugs, rough edges, and ideas. Please include your OS, your
terminal, `sprat --version`, and what you expected to see.

For anything larger than a small fix, open an issue first so we can agree on the
approach before you write code.

## Working on Sprat

Sprat is an Elixir application; the versions are in `.tool-versions`. The
Development section of the README has the commands: `mix test` runs offline,
`mix sprat.board_demo` shows the board with demo data, and a dev release gives
you the `sprat` command users type. Suites that touch the real machine are
excluded by default (`--only real_machine`, `--only live`).

Board snapshots live in `test/fixtures/v4/board`; after an intended change to
how the board draws, accept the new ones with `UPDATE_GOLDEN=1 mix test`.

By contributing you agree that your contribution is licensed under the MIT
License, like the rest of the project.
