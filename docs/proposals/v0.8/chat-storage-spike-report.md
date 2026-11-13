# Chat-storage spike report (RubyLLM 2.2's persisted chat, part 5)

**Companion to:** [`rubyllm-spike-report.md`](rubyllm-spike-report.md) (the PR 1 spike; its "One turn per chat" section is the 2.1.1 side of this question), [`ai-plumbing-redesign.md`](ai-plumbing-redesign.md) (the plan, §19 item 5 and §20) and [`rubyllm-spike-prompt.md`](rubyllm-spike-prompt.md)
**Evidence:** branch [`spike/chat-storage`](https://github.com/josh-sanders/sure/tree/spike/chat-storage) @ [`94c02b4cd`](https://github.com/josh-sanders/sure/commit/94c02b4cd). It is never merged. All files below are on that branch: `db/migrate/20261112000000_create_ruby_llm_persistence_spike.rb`, `db/migrate/20261112000100_create_spike_writes.rb`, `app/models/spike_chat.rb`, `app/models/spike_message.rb`, `app/models/spike_write.rb`, `test/spike/chat_storage_spike_test.rb`. Tests replay with no keys and no network (`RubyLLM::TestHelper` stubs the provider replies; the stub sits inside the gem's real conversation loop, so persistence, claims, approvals, the queue and cancellation all behave as they do in production).
**Status:** a recommendation with its evidence, not a decision. What PR 6 ships is the maintainers' call. Calls made during the spike itself are marked as such. This file records what RubyLLM 2.2.0 does on the merged 2f stack; nothing here re-opens the 2.2 adoption (already called by @josh-sanders in the PR 1 spike, shipped on 2f by PR #4892).

## Where delivery item 5 stands, and what this report closes

Item 5 of the delivery plan had four parts:

1. **The version bump** — 2.1.1 → 2.2.0, Gemfile `~> 2.2`. Done, on PR #4892 (`28cd75e61`), merged into the 2f stack.
2. **The recorded tests replayed, the live ones recorded again** — done on 2f; CI green there, 16,094 runs, 0 AI-related failures, and the kilo / OpenRouter cassettes re-recorded.
3. **Jev on OpenRouter working again (#1264)** — done on 2f: `Ai::LegacyEnvConfig::Jev` accepts `…/alpha/decisions`, `parallel/decisions-fast:free` verified live (STARBUCKS → Coffee Shops 0.67, PAYROLL → Salary 0.99) and recorded.
4. **The chat-storage spike** — this report. Its result decides whether PR 6 stores chat on RubyLLM's persisted tables or on Sure's own claim (§8.4).

## The question

The PR 1 spike answered, on 2.1.1 and with Sure's code, the questions §8.4 turned into columns on `chats` (`claim_token`, `claimed_until`) and a renewal discipline ("One turn per chat", `chat_claim_test`). RubyLLM 2.2 ships "One Process at a Time" on its own Rails persistence instead. The four cases that came out of the 2.1.1 spike, and the plan's item 5 names them, are:

1. **Two Retry requests at the same moment** — both passed `retry_last_message!`'s check; the turn ran twice and the write tool wrote twice.
2. **A turn whose claim lapsed mid-call** (worker hung), another took over — with renewal before every tool run, one write; without, two.
3. **A message sent while a turn runs** — a second turn started at once on the same history.
4. **An approval clicked twice** — not covered by Sure's own claim at all; two resumes of the same tool.

This spike runs those four cases, plus three more, against **RubyLLM 2.2.0's persisted chat** (`acts_as_chat` / `acts_as_message`), minimized to what the claims need: a `SpikeChat` and `SpikeMessage` seeded from the gem's install templates, the gem's claim machinery untouched, a stubbed provider, and a `SpikeWriteTool` whose every call inserts a row — the row is the answer to "did the tool run twice?".

## Setup

- Branch `spike/chat-storage` @ `94c02b4cd`, based on `feat/ai-2f-review` @ `ad71c5e4a`, with RubyLLM **2.2.0** — the same version PR #4892 ships.
- Tables created by the migration follow the gem's install templates verbatim, trimmed to what the claims use: `ruby_llm_models` (the registry `acts_as_chat` belongs to), `spike_chats` (+ `cancelled`, `claim_token`, `claimed_until`), `spike_messages` (+ the persisted-reply columns), `ruby_llm_tool_calls` (+ `approval`, `claimed_until`), `ruby_llm_usages`, `ruby_llm_queued_messages`, `spike_writes`. The batch, MCP-credential, chat-file and provider-file tables were skipped: nothing in the claim semantics reads them.
- One registry row is seeded per test (`stub-model`, provider `openai`); `RubyLLM.configure { |c| c.openai_api_key = "stub-not-a-real-key" }` satisfies configuration; **no request leaves the process**.
- 8 tests, 26 assertions. Green on the merged 2f stack; the two concurrency tests were run across 12 seeds each (`--seed` 1–12 and 1–10), and the whole file across 3 further seeds.

## Results

| Case | Sure, 2.1.1 (`chat_claim_test`) | RubyLLM 2.2 persisted chat | Evidence |
|---|---|---|---|
| Two jobs race to complete the same chat | Two turns; duplicate write (today) / one turn, one answer (with Sure's claim) | **One turn, one write.** The losing process returns the latest message without calling the model | `chat_storage_spike_test` "two jobs racing to complete: exactly one turn runs" (fresh record per thread; `Thread#value` so a dying thread fails loudly) |
| A retry after the turn finished | Today nothing (after the first Retry) / Two turns on same-moment clicks without the claim; no-op with it handled in Ruby's tables | **No model call at all, ever.** `settled?` → the loop doesn't run; no second answer, no second write | "a retry on an answered chat makes no call and no second tool run" |
| A claim lapsed mid-turn (dead worker), another took over | One write (with renewal before the tool run); two without | **One write.** The expired claim is re-taken by the next run; the run releases the claim on completion, leaving no token behind | "the resumed run after a crashed one takes the claim and writes once" |
| A message sent mid-turn | A second turn at once (visually), with a claim the second re-enqueues and waits | **The message joins the running turn** at its next step (`steer: true`); `steer: false` queues for after the turn; each message joins exactly once | "a queued message sent mid-turn lands at the next step, not in parallel" |
| An approval clicked twice | Not covered by the claim | **One decision, one tool run — even concurrently.** The decision lands on the tool-call row through a conditional update; the second click changes nothing; the tool executes once | "an approval clicked twice is one decision and one tool run" (two threads, same row, `remember: false`) |
| A busy process holds the claim | The other process returned without running | Same, through `exclusively` / `running?` — verified directly | "two jobs complete the same chat: one claims, the other returns without running" |
| A cancellation requested from another process | Not built (Sure has no stop today; §12 designs one) | **The next turn aborts** with `RubyLLM::CancelledError` before any call; a seen-and-consumed request clears itself | "a cancellation requested from another process stops the next turn" |
| The per-attempt ledger | Sure wrote its own recorders | **RubyLLM writes one `ruby_llm_usages` row per attempt** on a persisted chat; a persisted chat cannot opt out of it | "the usage ledger writes rows for each attempt" |

## What the spike found beyond the four cases

Read from `ruby_llm-2.2.0` source, because the behaviors above rest on them:

- **Claims are leases, renewed by a heartbeat thread.** `RunClaims::CLAIM_LEASE = 60` and `CLAIM_RENEWAL = 15` (or a quarter of a shorter `max_run_time`). Renewal stops at the run's deadline, so a hung run counts as crashed and the chat is free. Tool-call rows are claimed individually (`claimed_until` per row), and a call waiting on earlier calls in its round keeps the chat's claim — "one process per tool call" included (`lib/ruby_llm/active_record/run_claims.rb`).
- **A cancelled run cannot be killed mid-request, but it is found.** `ChatCancellation` persists the request on `chats.cancelled`; the run polls at most once per second (`CANCELLATION_POLL_INTERVAL = 1.0`) and raises `CancelledError`. An unstarted turn therefore aborts deterministically (the test). The gem also ships `Chat.interrupted` ("claims held, expiry passed, not cancelled") for a reaper job (the chat UI template includes `ResumeInterruptedChatsJob`); Sure would want one equivalent for chats whose workers died mid-turn.
- **Approvals double as the rendezvous between processes.** `ChatApprovals` reads `approval` on the tool-call row (`pending` / `approved` / `remembered` / `denied`) rather than in-memory state; `decide_persisted_tool_call` is a conditional update (`result_id: nil`, unclaimed row wins or `ActiveRecord::Rollback`); `approve` on a running-or-answered call changes nothing (`lib/ruby_llm/active_record/chat_approvals.rb`, `chat_methods.rb:130`). `remember: true` makes the decision per chat for repeat calls of the same tool.
- **The queue joins exactly once by deletion.** `ChatQueue#take_one` wins by `delete_all == 1` on the row; the message is built inside the same transaction. A crasher puts the row back (`run_around_join` wraps; on failure the queued row survives).
- **Retry on an answered chat is a no-op, not a second turn.** `settled?` means `answered?` and nothing steering; the loop returns the latest message without calling the model (`lib/ruby_llm/chat.rb`, `#complete` / `#settled?`). This differs from Sure's current responder, which always streams.
- **The per-attempt ledger is not optional on a persisted chat.** `ChatRun#record_usage` → `persist_usage_entry` does an unguarded `ruby_llm_usages.create!` inside `Usage.transaction(requires_new: true)`; with the table absent it raises, rescues and logs a warn **per attempt** — so adopting persistence means creating `ruby_llm_usages`, not declining it. (The global `RubyLLM::Accounting::Usage.ledger` store *can* be declined: `ledger_available?` checks the table, and the railtie only sets it `||=`; but that path never runs for a persisted chat.) One insert per attempt is all it costs; Sure keeps `llm_usages` (`call_id` / `status`, §10) as the display store.
- **A run that finds the chat answered has nothing to do — silent rather than failing.** Combined with Sure's pending-bubble model from today (`AssistantMessage` built before the job runs), a Retry would wait forever on a bubble RubyLLM will never answer. The bubble question disappears if RubyLLM owns the streamed assistant row, which it does.

## What it costs to adopt persistence in PR 6

- **Additive changes on Sure's own tables:** `chats` gains `claim_token`, `claimed_until`, `cancelled` and a `ruby_llm_model_id` FK (the registry reference, optional in `acts_as_chat` but NOT NULL in the install template; existing chats backfill from `Ai::Model` rows). `messages` gains the persisted-reply columns (`cache_until_here`, `cache_ttl`, `thinking_text`, `thinking_signature`, `citations`, `server_tool_calls`, `raw_content`, `raw_reasoning`, `phase`, `continuation`, `finish_reason`).
- **New tables:** `ruby_llm_models`, `ruby_llm_tool_calls`, `ruby_llm_queued_messages`, `ruby_llm_usages` (see above). The batch / chat-file / provider-file / MCP-credential tables can wait — none is read by the claims.
- **A model registry to maintain:** `acts_as_chat` belongs to `ruby_llm_models`; PR 6 has to create or find the registry row for each of Sure's routed models (~a sync in the endpoint/model save path plus a backfill, roughly the same size as `Ai::LegacyEnvConfig`'s preset expansion; the probe still checks which model the server actually serves).
- **`messages.provider_state` (§18) goes away.** Gemini's thought signatures ride the gem's own columns (`messages.thinking_text`/`thinking_signature`; tool-call `thought_signature`), so §5.5's drop-on-switch rule reads those instead. `tool_calls.extra_content` (today's home for the same signatures, #4133) migrates into `ruby_llm_tool_calls` in the same PR; the mobile API keeps reading the same `messages` rows (#4421) plus rows that don't exist today but that it never needed.
- **Sure's `Chat` / `Message` become `acts_as_chat` / `acts_as_message`**; the assistant message streams into the same row RubyLLM persists, so PR 6's streaming path changes shape but not the tables Sure owns.
- **`Ai::Conversation` (§8.4) keeps its driver** — round cap, last-round `tool_choice: none`, turn deadline, `cancelled:` — on top of the gem's claims; Sure gives up the `claim_token`/`claimed_until` bookkeeping, the renewal discipline, the double-click approval dance and the cross-process cancel polling, all now upstream's problem, tested by this spike.
- **One cost the PR 1 report already accepted:** `ruby_llm` majors ship fast; Sure pins at PR 9 and names a maintainer then. This spike ran on 2.2.0 as pinned by #4892; PR 6 should re-run `bin/rails test test/spike` against its own base before it lands.

## What it would cost to stay on Sure's own claim

Per-case additions Sure would have to build and maintain itself: the approval rendezvous (a `pending` decision on the tool call, a conditional update, double-click safety), the cross-process cancel poll, mid-turn steering (or an explicit wait-only rule forever), an `interrupted`-equivalent reaper, and the renewal discipline re-audited whenever the loop gains a new consumption point. The 2.1.1 spike's own finding — a 1-second claim lost on a busy CPU, two writers — required a full-suite re-run to catch; on 2.2.0 the equivalent class of bug is upstream's, and behind this spike's 12-seed stability runs. None of those are large alone; together they are most of "chat", before any of chat's own scope.

## Not tested, and worth keeping straight

- **No live HTTP.** Every reply here is scripted; provider chunk shapes, real SSE delivery, Gemini's signatures across a persisted round trip, and tool streaming are `#4892`'s live-test surface, replayed green on 2f at `d55dc808a`. This spike claims nothing about them.
- **Threads in one process.** The racing test forks two `Thread.new` blocks inside one process (the 2.1.1 spike had the same caveat); two Sidekiq workers or pods are not exercised. The conditional updates on the rows are the actual mechanism, and they do not observe process boundaries.
- **Mid-stream cancel.** The unstarted-turn abort is tested deterministically; a stop requested during a real streamed response lands at the next chunk boundary (the gem polls, at one-second intervals, while streaming) — untested here because there is no stream to interrupt.
- **The `interrupted` scope** is read from source, not run end-to-end; a reaper job for Sure-owned tables has no Sure-side precedent yet.
- **The registry path** is exercised only through the stub (`assume_model_exists` not needed: the seeded row resolves). A misconfigured `Ai::Model` → silent `resolve_model` fallback semantics (`assume_model_exists`) are out of scope.
- **Re-run before PR 6:** this ran on the 2f stack at `ad71c5e4a`. PR 6 should re-run against the merged chain (`main` → … → 2f) with the same command.

## Recommendation

**Adopt RubyLLM 2.2's persistence for chat storage in PR 6** — `acts_as_chat` / `acts_as_message` on Sure's `chats`/`messages`, with `ruby_llm_models`, `ruby_llm_tool_calls`, `ruby_llm_queued_messages` and `ruby_llm_usages`, keeping `llm_usages` as the usage store and Sure's own tables as the mobile API reads them. The four cases the plan named all pass, two of them better than Sure's own claim can express (mid-turn steering; the double-clicked approval), and the two largest recurring risks from the 2.1.1 spike (claim renewal; the approval race) are no longer Sure's code to maintain.

Not a decision: the inventory of Product calls in the register below is for the maintainers. This report should reach PR 6 either way it is made; §8.4's claim paragraph and §18's `provider_state` line are written against PR 1's recommendation and need rewriting once the call lands.

## Decisions register additions

- **Chat storage.** RubyLLM persisted (recommended, evidence above) vs Sure's claim (§8.4 as written). **Recommendation by this spike; the call belongs to the maintainers** (the storage line in §20 was already marked "decides at PR 5"). If the call is "Sure's claim", §8.4 keeps its shape and this report's per-case table is the shopping list for what Sure must then build.
- **Retry semantics.** Sure lets RubyLLM own the assistant row; Retry on an answered chat never re-sends — it shows, or repairs a failed turn. This is a product call (what “Retry” means to a user), with a technical consequence (blank pending bubbles are dead).
- **The `ruby_llm_usages` table.** Adopt it as an unavoidable side effect (per-attempt ledger), keep `llm_usages` as the display store; do not migrate or retire the latter in this plan. Alternative — declining it — is not available without log spam on every attempt.
- **`messages.provider_state`.** Drop from §18; the gem's columns carry the same facts. Keep `messages.route`-style provenance there instead (endpoint/model for "which model answered").

## How to re-run

```
cd sure-chat-storage-spike        # branch spike/chat-storage @ 94c02b4cd
bin/rails db:migrate RAILS_ENV=test
PARALLEL_WORKERS=1 bin/rails test test/spike
```

Expected: 8 runs, 26 assertions, 0 failures.
