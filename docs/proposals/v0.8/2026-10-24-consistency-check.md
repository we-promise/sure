# Consistency check (2026-10-24)

Every claim that appeared in more than one document, or that two documents stated differently, was checked against `main` @ `e5b854536`. Where the documents disagreed, the code decided.

| Claim | Was | Code says | Fixed in |
|---|---|---|---|
| Registered assistant tools | "48 registered" (01 D5.7) vs "30, 44 with preview" (00, 01, 02, 03) | 30 default + 14 preview = 44. The 4 tag/category write tools are removed for guests, not extra tools. 16 of the 30 write data, 21 of the 44. | 01 W13, D5.7; 02 A13 |
| AI env vars | "about 50" (02, 03), "about 25 tuning" (05) | 54 AI variables are read by the app; about 30 are tuning values once secrets, endpoints, identities and process sizing are removed | 05 BC5; 01 D1 (adds `AI_DEBUG_MODE`, `LANGFUSE_REGION`) |
| Precedence code to replace | "about 40 hand-rolled precedence methods" (02 S6, 05) | 68 methods in models, controllers and `lib` read an AI env var themselves, plus 41 `ENV` reads in the AI settings views | 02 S6; 05 BC5, §4 |
| AI job failure handling | "5 AI jobs with copied rescue/callback code" (02 S5) vs drift 5 (01 D5.6) | 2 jobs copy the `RuleRun` block, `ProcessPdfJob` has its own, 2 declare nothing | 02 S5 |
| Open PRs | "≥200" (02, 03) vs 330 (06) | 329 open on 2026-10-24 | 02 §1, B6; 03 §6 |
| Hot files | `config/sidekiq.yml` and `TransactionResource` listed as hotspots (02 B9) | `sidekiq.yml`: 1 commit in six months, no open PRs. The real hotspots are the files in 06 §1. | 02 B9 |
| Registries and collisions | "registries rarely conflict" (02 O-B7) vs F-H4 (06) | Each registry is one hand-written array; `assistant.rb` is changed by 14 open PRs | 02 O-B7 |
| Async rule-action result | `{async: true, jobs_count:}` (01 W8, 05 BC2) vs D5 I10 | `{async: true, modified_count:, jobs_count:}` | 01 W8, D5.7; 05 BC2 |
| AI cache reset button | "debug or rules page" (01 W21, 03 §5) | Rules page only (`rules/index.html.erb`) | 01 W21; 03 §5 |
| Classifier-rule migration | "on if the family had an active AI rule" (03 §7.0) vs "of the matching type" (01 W4, D4) | Matching type: AI merchant rule → matcher, AI categorization rule → classifier | 03 §7.0 |
| Advanced settings group | 11 items listed (03 §7.0) | 13: Imports and Exports were missing (29 entries in all, Maybe had 14) | 03 §7.0 |
| Line references | `rule.rb:233`, `chat.rb:59`, `sidekiq.rb:66` (01) vs `chat.rb:60` (04) | `rule.rb:253` (`apply`), `chat.rb:60` (`default_model`), `sidekiq.rb:68` (`AutoSyncScheduler.sync!`) | 01 B1, W4, A2 |
| Rails version | 8.1.3 (04) | 8.1.3.1, json 2.21.2 | 04 §3 |
| Reference commit | `56105a3b5` (01–03) vs `2250ba801` (04–06) | The commits since `56105a3b5` change no AI/ML code; every checked claim holds at `e5b854536` | 01, 02, 03 headers |

Checked and consistent: the tool split above, the 13 rule executors, the 8 insight generators, the 6 `#2113` comments, the duplicated helpers (5 / 4 / 4), the 16 guides and 7 Cursor rules, the 31 classifier settings, the six AI prompt keys, the model and timeout defaults (`gpt-4.1`, 60 s; `claude-sonnet-4-6`, 600 s, 4,096 tokens; context window 2,048; 8 tool rounds; chat timeout 90 s, minimum 30 s), the 0.7 confidence-threshold schema default, the AI compose values, the job queues and cron times, the Debug log being super-admin only, and Maybe v0.6.0's 4 read-only tools.

Found in the code itself and recorded in 01 D4: the AI compose file's comment still assumes a default of 5 tool rounds (#13), alongside the existing confidence-threshold comment (#11).

Contributors: the brief gave 446, and the GitHub contributors API lists 419 accounts (424 with anonymous). 03 now says **about 450**.
