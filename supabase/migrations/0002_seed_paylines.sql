-- ============================================================================
-- ⚠ ALREADY APPLIED — DO NOT RUN THIS FILE AGAIN.
-- It would also reset every payout-ladder multiplier to its original value,
-- wiping anything changed since in Back office → Payout rules.
-- Kept as history only. See supabase/README.md.
-- ============================================================================

-- bluePi Slot — 0002 seed: the 29 paylines and the payout ladder.
-- Generated from the requirements doc's cell highlighting. Do not hand-edit.

insert into slot.payline (id, family, cells) values
  (1, 'straight', array[array[0,0],array[0,1],array[0,2],array[0,3],array[0,4]]::smallint[][]),
  (2, 'straight', array[array[1,0],array[1,1],array[1,2],array[1,3],array[1,4]]::smallint[][]),
  (3, 'straight', array[array[2,0],array[2,1],array[2,2],array[2,3],array[2,4]]::smallint[][]),
  (4, 'straight', array[array[3,0],array[3,1],array[3,2],array[3,3],array[3,4]]::smallint[][]),
  (5, 'straight', array[array[4,0],array[4,1],array[4,2],array[4,3],array[4,4]]::smallint[][]),
  (6, 'diagonal', array[array[0,0],array[1,1],array[2,2],array[3,3],array[4,4]]::smallint[][]),
  (7, 'diagonal', array[array[0,4],array[1,3],array[2,2],array[3,1],array[4,0]]::smallint[][]),
  (8, 'corner', array[array[0,0],array[0,4],array[4,0],array[4,4]]::smallint[][]),
  (9, 'zigzag', array[array[0,0],array[1,1],array[0,2],array[1,3],array[0,4]]::smallint[][]),
  (10, 'zigzag', array[array[1,0],array[2,1],array[1,2],array[2,3],array[1,4]]::smallint[][]),
  (11, 'zigzag', array[array[2,0],array[3,1],array[2,2],array[3,3],array[2,4]]::smallint[][]),
  (12, 'zigzag', array[array[3,0],array[4,1],array[3,2],array[4,3],array[3,4]]::smallint[][]),
  (13, 'zigzag', array[array[0,0],array[1,1],array[2,0],array[3,1],array[4,0]]::smallint[][]),
  (14, 'zigzag', array[array[0,1],array[1,2],array[2,1],array[3,2],array[4,1]]::smallint[][]),
  (15, 'zigzag', array[array[0,2],array[1,3],array[2,2],array[3,3],array[4,2]]::smallint[][]),
  (16, 'zigzag', array[array[0,3],array[1,4],array[2,3],array[3,4],array[4,3]]::smallint[][]),
  (17, 'hill', array[array[4,0],array[4,1],array[3,2],array[4,3],array[4,4]]::smallint[][]),
  (18, 'hill', array[array[3,0],array[3,1],array[2,2],array[3,3],array[3,4]]::smallint[][]),
  (19, 'hill', array[array[2,0],array[2,1],array[1,2],array[2,3],array[2,4]]::smallint[][]),
  (20, 'hill', array[array[1,0],array[1,1],array[0,2],array[1,3],array[1,4]]::smallint[][]),
  (21, 'hill', array[array[4,0],array[3,1],array[3,2],array[3,3],array[4,4]]::smallint[][]),
  (22, 'hill', array[array[3,0],array[2,1],array[2,2],array[2,3],array[3,4]]::smallint[][]),
  (23, 'hill', array[array[2,0],array[1,1],array[1,2],array[1,3],array[2,4]]::smallint[][]),
  (24, 'hill', array[array[1,0],array[0,1],array[0,2],array[0,3],array[1,4]]::smallint[][]),
  (25, 'vertical', array[array[0,0],array[1,0],array[2,0],array[3,0],array[4,0]]::smallint[][]),
  (26, 'vertical', array[array[0,1],array[1,1],array[2,1],array[3,1],array[4,1]]::smallint[][]),
  (27, 'vertical', array[array[0,2],array[1,2],array[2,2],array[3,2],array[4,2]]::smallint[][]),
  (28, 'vertical', array[array[0,3],array[1,3],array[2,3],array[3,3],array[4,3]]::smallint[][]),
  (29, 'vertical', array[array[0,4],array[1,4],array[2,4],array[3,4],array[4,4]]::smallint[][])
on conflict (id) do update set family = excluded.family, cells = excluded.cells;

insert into slot.payout_ladder (lines, multiplier) values
  (1, 0.5),
  (2, 0.75),
  (3, 1.1),
  (4, 1.25),
  (5, 1.5),
  (6, 1.75),
  (7, 2.0),
  (8, 2.25),
  (9, 2.5),
  (10, 2.75),
  (11, 3.0),
  (12, 3.25),
  (13, 3.5),
  (14, 3.75),
  (15, 4.0),
  (16, 4.25),
  (17, 4.5),
  (18, 4.75),
  (19, 5.0),
  (20, 6.0)
on conflict (lines) do update set multiplier = excluded.multiplier;

insert into slot.setting (key, value) values
  ('bet_options',            '[25,50,75,100,125,150]'::jsonb),
  ('free_point_ceiling',     '1000'::jsonb),
  ('free_point_grant',       '200'::jsonb),
  ('first_login_grant',      '500'::jsonb),
  ('free_spins_per_round',   '10'::jsonb),
  ('free_spin_rounds_max',   '3'::jsonb),
  ('yellow_card_bets',       '5'::jsonb),
  -- OPEN QUESTION: max wilds allowed on a 5-cell line (Corner is fixed at 1 by the doc).
  ('max_wilds_per_line',     '2'::jsonb),
  -- OPEN QUESTION: does the special bonus break the x6 ceiling?
  ('cap_final_multiplier',   'false'::jsonb),
  ('max_multiplier',         '6'::jsonb)
on conflict (key) do nothing;
