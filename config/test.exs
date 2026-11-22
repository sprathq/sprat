import Config

# The application-supervised Sprat.Store singleton must never touch the
# real user data dir during `mix test`. Individual Store tests start their
# own isolated instances against their own temp files/dirs regardless.
#
# `MIX_TEST_PARTITION` alone isn't enough to make this path unique: it
# defaults to "0" whenever it isn't explicitly set (i.e. on every normal
# `mix test` run), so two *different* worktrees or checkouts of this repo
# running `mix test` concurrently on the same machine both resolved to the
# exact same `$TMPDIR/sprat-test-0` — a real, reproduced collision (one
# suite's Sprat.Store fighting the other's over the same sqlite file), not
# the production path but an equally-real shared one. Mixing in a hash of
# the checkout's own path (stable across a run, different per
# worktree/clone) makes it unique per checkout regardless of partition.
config :sprat,
  data_dir:
    Path.join(
      System.tmp_dir!(),
      "sprat-test-#{:erlang.phash2(File.cwd!())}-#{System.get_env("MIX_TEST_PARTITION", "0")}"
    )
