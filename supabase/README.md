# bluePi Slot — database

Everything the game does lives in Postgres on Supabase: the win engine, wallets,
free spins, rewards, requests, permissions. The website only calls functions in
the `public` schema; the real work is in the `slot` schema.

## The one rule: run each migration once, in order

Files in `migrations/` are run by hand in the Supabase SQL editor, **once each, in
number order**, and never again. Later files often replace a function from an
earlier one, so re-running an old file silently puts the old version back. The
riskiest old files carry a **⚠ ALREADY APPLIED** banner at the top saying exactly
what would break. For example, running `0007` again stops the daily free points;
running `0015` again makes every spin fail.

If you're not sure whether a file has been run, don't run it again. Ask first.

| Status | Files |
|---|---|
| Applied | 0001–0027 (there is no 0013: it was rolled back and removed) |
| To run next | 0028 (permissions tidy-up) |

## Where the current version of each function lives

Only functions defined more than once are listed. Everything else is in exactly
one file.

| Function | Current version | Older versions (don't re-run) |
|---|---|---|
| `slot.evaluate_grid` — scores a spin | 0027 | 0003, 0004, 0021 |
| `slot.spin` — one spin, start to finish | 0022 | 0005, 0008, 0014, 0015 |
| `slot.explain_grid` — "why did that line win/lose" | 0018 | 0015 |
| `slot.game_ready` | 0016 | 0008 |
| `slot.claim_account` — first sign-in | 0023 | 0007 |
| `slot.grant_free_points` — automatic free points | 0023 | 0007 |
| `slot.register_email` | 0024 | 0007, 0020 |
| `slot.set_display_name` | 0024 | 0023 |
| `slot.request_points` | 0026 | 0023 |
| `slot.setting_int`, `slot.setting_bool` | 0011 | 0003 |

Scheduled jobs (pg_cron, all times UTC; Bangkok is +7):

| Job | When | Defined in |
|---|---|---|
| `bluepi-slot-free-points` | daily 05:00 (12:00 BKK); pays only on scheduled weekdays | 0023 |
| `bluepi-slot-expire-requests` | hourly at :07 | 0023 |
| `bluepi-slot-prune-history` | daily 20:30 (03:30 BKK) | 0022 |

## Writing a new migration

- **Name:** the next number, plus a few words: `0029_something.sql`. Start with a
  comment saying what changes and why, in plain words.
- **Functions:** put them in `slot`, and add `security definer set search_path = ''`
  for anything that reads or writes on the caller's behalf. Use fully qualified
  names (`slot.wallet`, not `wallet`). Check the caller's role inside the function
  (`slot.is_admin()`, etc.) rather than relying on the website.
- **Website entry point:** add a thin `public.<name>` wrapper that just calls the
  `slot` function. PostgREST only exposes `public`.
- **Permissions:** Postgres lets everyone (PUBLIC) call a new function by default.
  So `revoke execute ... from public, anon`, then `grant execute ... to
  authenticated` for anything the website calls. Running `0028` again does this for
  every function at once, and is safe to repeat.
- **Replacing a function:** `create or replace` drops its `set search_path`, so
  write the setting again in the new version. Then add the function to the table
  above, and put the ⚠ banner on the file that held the old version.
- **Safe to run twice:** use `if not exists`, `on conflict`, and
  `drop policy if exists`, so running a file twice by accident does no harm.

## Tests

`./run_tests.sh` (from the project folder) builds a scratch database from every
migration, then runs all the suites in `tests/`. It needs a **local** Postgres 16.
**Never point it at Supabase**: the tests delete data.

## Diagnostics

`diagnostics/why_did_that_line_lose.sql` contains read-only queries for checking a
logged spin by hand in the SQL editor.
