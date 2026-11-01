# RubyLLM spike report (PR 1 of the AI plumbing redesign)

**Companion to:** [`rubyllm-spike-prompt.md`](rubyllm-spike-prompt.md) (the brief), [`ai-plumbing-redesign.md`](ai-plumbing-redesign.md) (the plan, §19) and [`04-rubyllm-thought-experiment.md`](04-rubyllm-thought-experiment.md) (the question before it was run)
**Evidence:** branch [`spike/ruby-llm`](https://github.com/josh-sanders/sure/tree/spike/ruby-llm) @ [`f01c6d3de`](https://github.com/josh-sanders/sure/commit/f01c6d3de). Every test and recording named below is on that branch; it is never merged. The tests replay without keys (the commands are under the recommendation); `SPIKE_RECORD=1`, with the spike's own variables in `.env.local`, records them again.
**Status:** a recommendation with its evidence, not a decision. The spike's second purpose was to sort the plan's choices into product decisions and technical limits; none of the product decisions, and none of the scope lines, is final. Calls made by @josh-sanders during development of PR #4440 are marked in the register. This file is the spike's note (`docs/llm-guides/ai-pipeline.md` on the branch) as of that commit; the plan's own short note in that path comes with PR 2.

**Recommendation: adopt `ruby_llm`**, tested on 2.1.1 (released 2026-10-11, the latest at the
start of the spike). Every criterion in section 19 of the plan passes or has a small fix. None
fails. **Call by @josh-sanders during development of PR #4440:** adopted, on 2.1.1 from PR 2 and 2.2 from PR 5
(not waited for), with the Gemfile at `~> 2.1` during delivery and pinned when PR 9 lands.
Like every product decision it stays open: the evidence on both sides is in the decisions
register below.
Live runs: llama.cpp on the test host (20 CPU cores, no discrete GPU); Ollama, LM Studio and OpenClaw in temporary containers (see
"Local servers in containers"); Gemini through Google's OpenAI-compatible API
(`gemini-3.5-flash-lite`); OpenRouter's chat completions with free models (see "OpenRouter chat
on free models"); and Jev's protocol on OpenCode Zen and OpenRouter's decisions gateway.
The Anthropic and OpenAI keys have no credits, so only their error paths ran live (see "Anthropic
and OpenAI on keys without credits").
Their rows are judged from RubyLLM's source and from WebMock stubs in each provider's documented
shapes, and are marked "not tested live". PR 2 should record live cassettes for them before it
relies on them.

RubyLLM doesn't save lines in `generate`; its adapter is longer than the hand-written one. The
case for it is everything else:

- **Chat streaming:** one parser covers chat completions, Anthropic and the Responses API, and
  it preserves Gemini's `reasoning_details` and Anthropic's thinking signatures between rounds.
  Today's chat transport is about 855 lines.
- **One HTTP stack:** Faraday takes an explicit proxy for every provider. The `anthropic` gem
  can't take one (see the proxy row).
- **Unknown models:** `assume_model_exists` handles models missing from the registry.

Sure keeps the turn's bounds (it steps the tool loop; RubyLLM can run the tools, see "RubyLLM
agents behind the gate"), the JSON-mode policy, error mapping, instrumentation and the routing
around it.

Branch: `spike/ruby-llm` (not merged). Tests: `bin/rails test test/models/ai test/models/pdf test/models/vector_store/openai_live_test.rb` (377 runs, 57 skips:
the live-only timeout, Red Candle and job-runner tests, and OCR combinations not recorded), and for Jev `bin/rails test test/models/provider/jev_test.rb
test/models/provider/jev_gem_test.rb test/models/provider/jev_gem_live_test.rb` (62 runs). Live server: llama.cpp on the test host, `qwen3.6-35b-a3b-mtp` (64k context,
`--jinja`, tool calls on) and `granite-embedding-small-english-r2` (384 dimensions). Neither model
is in RubyLLM's registry. Cassettes are under `test/vcr_cassettes/ai/llama_cpp/`.

## Criteria

| Criterion | Result | Evidence |
|---|---|---|
| Models missing from RubyLLM's registry still work (`assume_model_exists`) | Pass | Every live call used unregistered models. `generate_stubbed_test` "OpenRouter strict mode, model missing from the registry" asserts `ModelNotFoundError` from the registry, then a working call. With `assume_model_exists` the lookup failure falls back to `Model.default` (`lib/ruby_llm/models.rb:198-212`) |
| One URL normaliser handles `/v1` for every compatible server | Small fix: Sure's `Ai::Transport::Http.compatible_base` feeds `openai_api_base` (or `openrouter_api_base`). It adds `/v1` only to a bare host and keeps a URL with a path, because Gemini's compatible base is `/v1beta/openai` | `generate_llama_cpp_test` "base URLs with or without /v1…" (live, `generate_base_url_{0,1,2}`); `gemini_live_test` (live, posts to `/v1beta/openai/chat/completions`); Ollama without `/v1` in `generate_stubbed_test`; `http_test` |
| Prompts, outputs and each tool-loop step reach Langfuse | Pass, through Sure's own `.ai` events, not RubyLLM's | `test/models/ai/live/langfuse_check.rb` against a self-hosted Langfuse v4: one generation for `generate.ai`, then one `converse.ai` per round (round 1: `user`; round 2: `user>assistant>tool`), with prompt, output and usage, grouped by the correlation id as the session. The pod runs in `events_only` mode, so the check reads `/api/public/v2/observations`. RubyLLM's own OpenTelemetry tracing sends no content and is the `metadata` mode; see "Tracing modes" |
| Tool loops stay under `Ai::Conversation`'s bounds, not the gem's own loop | Pass | `Chat#generate` makes one completion and doesn't run tools (`lib/ruby_llm/chat.rb:196-209`); `#ask`/`#complete` are the gem's loop and aren't used. `converse_test` "llama.cpp streams a tool call…" (live, `converse_tool_round`) expects `RubyLLM::Tool#call` never to run; the last-round and turn-deadline tests cover both bounds |
| The default retries and timeout are overridden by the endpoint's settings | Pass | `errors_test`: 429, 500, 503 and a read timeout give one request with the endpoint's `max_retries: 0`, and four with RubyLLM's defaults (`max_retries = 3`, `request_timeout = 300`, so one call can wait 1,200 s plus backoff). Live: a 2 s timeout against a slow llama.cpp request raises `Ai::Error::Timeout` with one attempt per transport |
| LM Studio's rejection of strict schemas and the `auto` fallback still work | Pass. Live, LM Studio no longer rejects strict schemas, so the fallback is proved by stubs | `lmstudio_live_test` (live, llmster 0.0.25): strict `json_schema` with `reasoning_effort: "low"` is accepted by both transports, `json_object` is refused with a 400 (`'response_format.type' must be 'json_schema' or 'text'`) and becomes `Refused`, and `none` parses the prompted shape. `generate_stubbed_test` "LM Studio rejects strict and json_object…" still proves the chain: strict → 400 → `json_object` without effort → 400 → `none` with the schema example, parsed from a fenced block. A mostly-null answer moves on and keeps the effort |
| Anthropic models that reject a forced tool still return structured output (#4513) | Pass; not tested live | `generate_stubbed_test` "Anthropic forces the tool…" and "Anthropic auto model…": `tool_choice` `tool` vs `auto`, one retry with the reminder, and both attempts billed. Uses `Provider::Anthropic.forced_tool_choice_supported?` |
| `<think>` blocks are stripped | Small fix: Sure's parser strips them; RubyLLM only separates `reasoning_content` | `generate_llama_cpp_test` "an inline think block is stripped…" (live, `reasoning_format: none`, `enable_thinking: true`; the cassette's content holds `</think>`). For chat, inline `<think>` in a stream would reach the user; servers that split reasoning (llama.cpp's default) don't send it inline |
| Tool calls stream on Ollama, llama.cpp and LM Studio | Pass, live on all three | `converse_tool_round` cassettes under `llama_cpp/`, `ollama/` and `lmstudio/`: `get_accounts` is called on round one, Sure runs it, and the answer streams on round two (`ollama_live_test`, `lmstudio_live_test`, through the shared `local_server_live_tests.rb`). On llama.cpp the call arrives as `{` then `}` deltas and is reassembled. `converse_stubbed_test`: Ollama style (whole calls, no `index`) and LM Studio style (fragments keyed by `index`), accumulated by `lib/ruby_llm/protocol/stream_accumulator.rb:125-165` |
| Gemini thought signatures survive gateways | Pass, live through Gemini's OpenAI-compatible API; OpenRouter's `reasoning_details` round trip live with Nemotron, Gemini on OpenRouter stubbed (paid) | `gemini_live_test` (live, `gemini/converse_two_rounds`, `gemini-3.5-flash-lite`, effort `low`): three rounds. Round 2 sends one tool call's `extra_content.google.thought_signature` back and round 3 sends both (`protocols/chat_completions/tools.rb:59-61, 117`). Without them Gemini answers 400 "Function call is missing a thought_signature" (`gemini/round_two_without_signatures`). On OpenRouter, `converse_stubbed_test` "OpenRouter Gemini…" sends `reasoning_details` back on rounds 2 and 3. Small fix: the OpenRouter preset must use RubyLLM's `:openrouter` provider (`providers/openrouter/chat.rb:90-102`); the generic `:openai` provider drops them |
| Every client honours the resolved proxy | Pass | `test/models/ai/live/proxy_check.rb` through a logging forward proxy: RubyLLM's compatible, embed, Anthropic and OpenRouter clients go through it with `HTTPS_PROXY` only and with `HTTP_PROXY` only, and skip it for `NO_PROXY` hosts. The hand-written Anthropic transport (the `anthropic` gem) ignores `HTTPS_PROXY`: Net::HTTP reads only `http_proxy` even for TLS, and the gem takes no proxy option. Also live on Ollama, LM Studio and OpenClaw (see "The proxy with local servers"), where Sure proxies loopback addresses that Ruby's own lookup would not |
| Every error maps onto `Ai::Error` | Pass | `errors_test`. Live on llama.cpp: bad key → `Unauthorized` ("Invalid API Key"), oversized prompt → `ContextTooLong` ("request (287168 tokens) exceeds the available context size (65536 tokens)"), refused port → `Unreachable`. Live on Ollama: an unknown model → 404 → `Refused`; an oversized prompt → `ContextTooLong`. Live on LM Studio: an oversized prompt → `ContextTooLong` (its llama.cpp engine's 400, wrapped as "Engine protocol predict request returned 400: …"). LM Studio's errors are `{"error": "<string>"}`, not OpenAI's `{"error": {"message": …}}`: RubyLLM parses them, and the hand-written transport crashed with a `TypeError` until it was fixed. Live on OpenClaw: a wrong gateway token → 401 → `Unauthorized`, after one attempt. Live on Anthropic, both transports: no credits → 400 → `Refused`, and a wrong key → 401 → `Unauthorized`, each after one request. Live on OpenAI: no credits → 429 `insufficient_quota` → `RateLimited`, sent three times by RubyLLM (`max_retries: 2`) and once by `ruby-openai`; a wrong key → 401 → `Unauthorized`. Live on OpenRouter: a wrong key → 401 → `Unauthorized`; a paid model on a key without credits → 402 → `Refused`, after one request; a free model's shared upstream limit → 429 → `RateLimited` (seen three times, not recorded). WebMock: 429, 5xx, 529, OpenAI/OpenRouter, LM Studio and Anthropic context-length wording, and a connect timeout → `Unreachable` |
| The Responses API and vector stores work through it, or the `responses_api` path stays hand-written | Small fix: Responses `generate` goes through RubyLLM; vector stores stay on `ruby-openai`. Responses ran live only to its error path (the key has no credits); vector stores ran live (see "OpenAI vector stores with the sample statements") | `generate_stubbed_test` "an endpoint with responses_api…": `text.format` strict JSON schema, `reasoning.effort`, `store: false`. RubyLLM's Responses protocol is stateless by design (`lib/ruby_llm/protocols/responses.rb:5-8`) and never sends `previous_response_id`. It has no vector store calls, only the `file_search` server tool, so `VectorStore::Openai` keeps `ruby-openai` |
| Lines removed for `bill_setup` against the hand-written version | Reported below | RubyLLM's `generate` is 26 lines longer than the hand-written one |

Chatwoot's #16078 kept audio transcription and embeddings on their dedicated OpenAI endpoints
because the Responses API it moved text inference to has no equivalent for them. It wasn't a
judgement of RubyLLM: Chatwoot still embeds through `RubyLLM.embed`
(`enterprise/app/services/captain/llm/embedding_service.rb`), without `assume_model_exists`.
`embed` over RubyLLM passes here: `embed_test` (live, `embed`) returns two 384-dimension vectors
and one `embed.ai` event.

## Decisions register

The spike's second purpose is to sort the plan's choices into **product decisions** and
**technical limits**, and to gather evidence on both sides of every product decision. Nothing
here is final, and that includes scope: an "out of scope" line is a product decision too.
- **A technical limit** is something a server, a gem or a protocol does, recorded live or read
  in the source, often with a known workaround.
- **A product decision** is Sure's choice, with the evidence for and against it so far.

The first table holds the decisions with evidence on at least one side. The second lists those
with none yet, including the plan's own design choices, its "not in scope" lines (§20) and the
questions RubyLLM's features raise, with what would test each.
Where @josh-sanders has made a call during development of PR #4440, the decision says so. A call is a proposal for the maintainers to accept or overturn, and it stays open to new
evidence like everything else here.

**Product decisions**

| Decision (plan section) | For | Against | Evidence |
|---|---|---|---|
| Adopt RubyLLM for the transports (§19). **Call by @josh-sanders during development of PR #4440:** adopted: 2.1.1 for PR 2, 2.2 when it's released without waiting for it, `~> 2.1` during delivery, pinned when PR 9 lands | One streaming parser for every protocol; an explicit proxy for every client; unknown models; Gemini signatures and `reasoning_details` kept | `generate` is 26 lines longer; fast releases; some fixes lean on private API (`usage_entries:`); five ecosystem gems still pin 1.x | Criteria; "What to watch on upgrade"; feature tests |
| Sure owns the tool loop (§5.5, §8.4) | Round cap, final round without tools, turn deadline, cancel; RubyLLM's `ask` has no round cap (12 rounds until the spike's guard) | `ask` needs no loop code; `run_tools` brings approvals, parallel tools and resume for about 40 lines; a `RubyLLM::Agent` stepped by Sure keeps the bounds and worked behind the gate, interrupted and resent without running a tool twice | "RubyLLM running Sure's tools"; "RubyLLM agents behind the gate"; `features/tool_loop` |
| Sure stores chat history, not RubyLLM (§8.4, proposal 04) | Mobile API and broadcasts unchanged; model picked per turn; no usage ledger | RubyLLM's history knows each message's producer and strips other providers' leftovers; approvals that survive restarts | "Switching providers"; RubyLLM install templates |
| Failover only at the start of a turn (§5.5) | No half-written answer from two models | Provider state can move (Google's placeholder signature); RubyLLM falls back even after chunks have streamed and reports it | `switch/placeholder_round_llama_gemini`; `fallback.rb` |
| Gemini through Google's OpenAI-compatible API (§4.2) | One more compatible server, one code path | Native provider continues other models' tool rounds, prices calls, and has Gemini-only features (search grounding, batches) | `switch/round_llama_gemini_native`; `features/cost` |
| The `auto` JSON-mode chain (§7). **Call by @josh-sanders during development of PR #4440:** keep it as the default, with the fixes: it stops on 400s unrelated to JSON, and each attempt has a time budget | Servers differ on strict schemas | Retries 400s unrelated to JSON (resent a whole PDF twice); re-asks when the answer is legitimately empty; a slow model's three attempts took 26 minutes | PDF and OCR spikes |
| Prompts as `.md` with `%{}`, no ERB (§8.3). **Call by @josh-sanders during development of PR #4440:** Sure's prompt files are ERB (RubyLLM's `render_prompt`, partials, agent instructions); family overrides stay plain text, put into the template as data and never compiled, because ERB runs Ruby and a family admin isn't trusted with the server | Family overrides are user text; ERB would run code | RubyLLM's agent instructions and 2.1 partials need ERB templates | RubyLLM 2.1.1's `Prompt` (`render_prompt`, partials, `.txt.erb`); discussion |
| Jev hand-written (§7). **Call by @josh-sanders during development of PR #4440:** Jev moves to RubyLLM's `judge` in PR 2 | Any gateway URL; no dependency | 72 lines to maintain; RubyLLM's `judge` works on OpenCode Zen; `ruby_decision_model` covers it in 54 | Jev section |
| PDF import: images for vision, text otherwise, unavailable for a scan (PDF spike). **Call by @josh-sanders during development of PR #4440:** Auto is the native PDF where the model has `documents` and the file is within the preset's provider limits, then the text layer in chunks, then images or OCR when the text is empty or fails its checks; it tunes itself per account and model from the last way that passed | Every right extraction came from those two inputs | Anthropic and OpenAI read PDFs natively (not tested live) | `statements/`, `ocr/` |
| Page rendering in a child process vs `ruby-vips` in process. **Call by @josh-sanders during development of PR #4440:** hardened `pdftoppm`, keeping #3275's choice | Child keeps poppler's memory away from the worker | `ruby-vips` is simpler, already bundled; the child needs limits to be worth it | `page_images_test` |
| Answer-free checks on extractions, `dates_anchored` ≥ 0.5. **Call by @josh-sanders during development of PR #4440:** a failing extraction is offered for review, flagged, never dropped (#3105, #1753); the balance check uses #4054's balances from the text where found | Separated all 14 right from all 12 wrong recordings | Threshold tuned on two statements | "Checks on an extraction" |
| OpenAI vector stores vs pgvector (§5.5). **Call by @josh-sanders during development of PR #4440:** keep the store pluggable as #961, #1211 and #1986 built it, with the spike's fixes | No embedding model to run | Indexing isn't awaited; scans index empty; no score threshold; files outlive removal | `openai/vector_store_statements` |
| Tracing: `content` vs `metadata` (§10). **Call by @josh-sanders during development of PR #4440:** both modes, in PR 2a | `metadata` sends no financial data | It loses route, prompt key, Sure's error class | "Tracing modes" |
| Sure is an MCP server, not a client (§20, proposal 04) | No third-party server gets family data | RubyLLM's client worked against Sure's own `/mcp` in process, negotiating down to 2025-06-18 and showing only the tools `only` allows | `ruby_llm_mcp_live_test` |
| RubyLLM's usage ledger off (no `ruby_llm_usages`); Sure writes `llm_usages`. **Call by @josh-sanders during development of PR #4440:** keep it off | The ledger has no feature, route, correlation id or metadata column, and its `operation` allows only RubyLLM's 11; local models have no price; `provider` is RubyLLM's slug (`openai` for llama.cpp); the table is RubyLLM's private model. (Jev would reach it once it goes through `judge` in PR 2d) | A row per attempt with its status, written with no Sure code; RubyLLM's usage owner follows its tool threads; prices for registry models; where RubyLLM's history finds a message's producer | "RubyLLM's usage ledger"; `ruby_llm_usage_ledger_test` |
| Usage from Sure's `.ai` events, one per call (§10). **Call by @josh-sanders during development of PR #4440:** one `llm_usages` row per request, from RubyLLM's `usage.ruby_llm` events with Sure's call context and a `call_id`; the usage page shows one row per call, summed, and a click opens its requests | Feature, route, error class and correlation id in one place, shared with Langfuse | A call of four requests (two retried 503s, the `auto` chain's 400, the success) was one event with the last request's tokens; RubyLLM's `usage.ruby_llm` event fires for every attempt and its subscriber sees Sure's context | `ruby_llm_usage_ledger_test` |
| Auto-upload of large files off. **Call by @josh-sanders during development of PR #4440:** keep it off; PDFs go inline as #1985 does | A statement never stays in a provider's Files API | Anthropic over 24 MB then can't take the file at all | `extract_statement_stubbed_test` |
| Chat storage redesign out of scope (§20). **Call by @josh-sanders during development of PR #4440:** spike RubyLLM 2.2's persistence when it ships (PR 5), then decide before chat | The plumbing needs one additive column; one turn per chat can be Sure's own claim (31 lines) | RubyLLM's persistence pays off if RubyLLM runs the loop; 2.2 (unreleased) adds one process per chat and per tool call, cancel from another process, and approvals safe against a double click, all on that persistence | "Switching providers"; "One turn per chat" |
| One turn per chat, with a claim on `chats` (§8.4) | Two jobs on one turn ran the write tool twice today; with the claim, once | Two columns and a renewal before every tool run, or a lapsed turn writes again; a turn waiting longer than the claim wastes its model call | "One turn per chat"; `chat_claim_test` |
| A message sent while a turn runs (today: a second turn starts at once) | Each message is answered as soon as possible | Two turns read the same history and ran at the same time; with a claim the second waits and runs after (re-enqueued), or could be refused | `chat_claim_test` |
| One ordered model list per feature, failover down the list, the only failover layer (§5.2, §5.4). **Call by @josh-sanders during development of PR #4440:** yes; the list is tried in order, skipping what's down, with no move limit | One list holds local servers, gateways and several models on one gateway; every model that may see the data is a visible entry; failover shows in marks, usage and the footer | A gateway's or RubyLLM's own fallback needs no entry per model | `failover_test` |
| What a failure marks down: the server, the key or the model (§5.4). **Call by @josh-sanders during development of PR #4440:** the smallest thing the error proves broken: the server when no response came back, or on a timeout or 5xx from a local endpoint; the key on a 401 or 403; otherwise the model. Anything else is for an issue | Marking the model keeps a gateway usable after one upstream's 503 or 429; marking the server is right for a hung local server; by location passed every case but a whole-key 429 | The plan's rule took a gateway's other models out for 60 s; marking only the model tried a second model on a hung local server and lost the call | "Failover on a gateway"; `failover_test` |
| No RubyLLM `with_fallbacks` inside an entry (not in the plan). **Call by @josh-sanders during development of PR #4440:** agreed | Sure saw model-a succeed while model-b answered: no mark, model-b's usage at model-a's price, nothing in the footer; an unlisted model ID can't be a fallback | One call, no extra entries; RubyLLM reports a switch after chunks streamed | "Failover on a gateway"; `failover_test` |
| A family's own key: its calls fail over only to routes on its own keys, never the operator's key or a local server, and the family admin is told (§4.2). **Call by @josh-sanders during development of PR #4440:** yes: the family gets what it chose, with no surprises | No bill for the operator and no data on a server the family didn't pick; a broken key is seen, not hidden | A local model or the operator's key could have answered | `failover_test` "a family's own key…" |
| Per-family cost caps (§20). **Call by @josh-sanders during development of PR #4440:** in scope for PR 9, only for a family that brings its own key: the family admin takes responsibility for that endpoint's configuration, the cap included | The family that pays sets the limit; usage per attempt already carries family and cost | Nothing caps a family on the operator's key; a cap checked before a call can overshoot by one call or batch; cost is known only for priced models | Discussion; usage-ledger spike |
| Local OCR as a two-step route (OCR model, then extraction). **Call by @josh-sanders during development of PR #4440:** both kinds: a local OCR model through chat, and Mistral or Cohere through `RubyLLM.ocr`, with live cassettes before relying on the cloud ones | Read both statements completely on CPU | Needs a second model or endpoint per route; a prompt per model | `ocr/` |
| AI jobs on Sidekiq threads, not fiber workers (§11) | 200 threads made 200 cloud calls in 3.1 s (fibers 3.0 s) on a pool of 3 connections, with the same memory; chat as fast as on fibers with a 1-thread chat capsule (48.3 s against 48.2 s); interrupting works on threads; no second job runner | Fibers need no chat capsule and no AI thread count, and waiting costs nothing; one capsule of 4 threads left chat 136 s without a thread; Solid Queue's `limits_concurrency` was the only limit shared across workers that was tested | "Job runners and chat priority" |
| Chat's wait behind background work on a local host: about 2 s, never more than 5 s. **Call by @josh-sanders during development of PR #4440:** the target | Chat felt broken at 45 s; interrupting meets it (0.09 s) with MTP and the full context kept | Only interrupting or a kept slot meets it; both cost background throughput or lost work | `gpu_merchants_live_test` |
| Chat interrupts the running background or prompt call on its host (§11). **Call by @josh-sanders during development of PR #4440:** the gate closes the call's connection, which also stops a prompt read (about 20 s against 209 s), keeping #4444's typing hold for long reads | Chat's first word at its time alone (48.3 s against 48.7 s) on 1 slot with MTP; public RubyLLM streaming only; threads and fibers | The interrupted call's work is lost (up to one call: 72 s at 25 transactions); a call still reading its prompt stops only when output starts; background calls on local hosts must stream | `sidekiq_preempt`, `preempt` |
| No slot kept for chat; several server slots are the operator's choice (§11) | Keeps MTP and the full context; chat finished in 69 s against 103 s with a kept slot, because it had the CPU | Four slots without MTP did 29 transactions a minute against 20 with one; a kept slot needs no interrupt code | `gpu_merchants_live_test` |
| Chat goes next, without interrupting (the plan before this) | No new mechanism | 45 s behind a 25-transaction call (up to 72 s), 8 s behind a 5-transaction one (up to 15 s) | `call_length`, `drain` |
| The gate inside RubyLLM's instrumenter, per request, sized from the server (§11). **Call by @josh-sanders during development of PR #4440:** per request, not per turn: on one slot llama.cpp kept chat's prompt across other calls between rounds | Every request passes it, streamed or not and with retries, embeddings and nested calls included, with no change where calls are made; no nested-call rule; llama-server's own queue stays empty | Holds per request, so a chat's tool rounds let background calls in between (the next round interrupts them); Jev's transport has to take it itself | `SlotInstrumenter`, `gpu_contention_live_test`, `drain` |
| One worker per local host (§11) | The in-process gate is then the only one | Two workers, each with its own gate, let 6 calls through to a 4-slot server and chat waited 200 s; a shared limit (Solid Queue's held, Redis untested) would allow more workers | `two_workers_slot_each`, `two_workers_limits_concurrency` |
| Fiber isolation for the whole app (needed by fiber workers) | Sure's full suite passed with it (13,944 runs; one timing failure that passes alone) | Every request and job changes; a fiber worker without it shares `Current` between jobs | `fiber_compat_live_test` |
| Each PR replaces code outright, with no bridge code (§19). **Call by @josh-sanders during development of PR #4440:** a principle, not a ban: avoid duplicated work, wrappers and temporary code, but allow them where the whole order is clearly better | One question per review ("is this replacement right?"), and no temporary state to reason about | It fixed chat before the gate and config in the database: the gate needs chat's requests to pass through RubyLLM, and config in the database leaves nothing on old code, so neither could land before chat without a bridge | §19's dependencies (read, not tested) |
| Build chat on RubyLLM 2.1.1 now, or wait for 2.2 (§19). **Call by @josh-sanders during development of PR #4440:** chat goes onto 2.2, so it's PR 6, after the 2.2 upgrade | Waiting builds chat once, on whichever chat storage the evidence picks; Jev can join the gate and usage through RubyLLM first | 2.2 has no release date; the gate (chat's wait, U1) and config in the database wait with chat; Sure's own claim already gives one turn per chat on 2.1.1 | rubyllm.com/next; "One turn per chat" |
| Jev's endpoint takes any full URL (`JEV_ENDPOINT`, §4.5). **Call by @josh-sanders during development of PR #4440:** no custom paths; OpenRouter's Jev stops working from PR 2 until 2.2 (PR 5); an issue can bring a path back | Any gateway at any path works | Keeps Jev's 72 hand-written wire lines and its own gate and usage code; RubyLLM's `judge` reaches fixed paths only: TypeSafe-style servers on 2.1.1 (live, OpenCode Zen), OpenRouter from 2.2 (#1264, read, not run) | "Jev"; `judge_jev_live_test` |
| Fix live chat bugs on `main` now, outside the redesign. **Call by @josh-sanders during development of PR #4440:** neither; both wait for chat (PR 6) | OpenClaw ignores Sure's agent headers, so a family's chats share one agent session, and two turns can run on one chat: both affect users today | The fixes touch code PR 3 replaces | "The external assistant"; `chat_claim_test` |
| The gate before chat, with today's chat taking it (§19, PR 4). **Call by @josh-sanders during development of PR #4440:** yes | Chat's wait behind background work (56–104 s on one instance) is fixed before chat moves to 2.2 | A few temporary lines in `Assistant::Responder`, deleted by PR 6; today's chat requests can't be interrupted (they never need to be) | "Job runners and chat priority"; §19 |
| Configuration in the database after chat (§19, PR 7). **Call by @josh-sanders during development of PR #4440:** yes | No wrapper for today's chat to read the new tables | The new settings pages wait for chat, and so for 2.2 | §19 |

**Product decisions with no evidence yet**

| Decision (plan section) | What would test it |
|---|---|
| `Ai::Usage` named `Ai::Tokens`, after `RubyLLM::Tokens`, beside v0.7.6's `Usage` (installation telemetry) and `LlmUsage` (§10). **Call by @josh-sanders during development of PR #4440:** yes | Nothing to test: a name |
| The user switch in PR 2b: today's checks, so chat and bills need `ai_enabled` and PDF import and documents don't; PR 7's migration uses who clicked "Enable AI Chats" (§6). **Call by @josh-sanders during development of PR #4440:** yes, nothing added to the prompt; indexing a vault upload (#3422) also needs the uploader's switch, since a vault upload isn't an AI action (§5.5) | How many users PR 7's migration finds with the switch on, and what it does for the rest |
| Configuration built per process until PR 7, as today, so the web and the workers can disagree (§19). **Call by @josh-sanders during development of PR #4440:** accept it; the upgrade guide says to give both the same AI variables | Installs whose web and worker AI variables differ |
| Shadow runs: the operator sets the rate and route, each family opts in (§8.2). **Call by @josh-sanders during development of PR #4440:** a separate switch per shadow feature, off by default, from PR 7, when the rate also moves to the instance; until then the rate stays on the family and shadow runs behave as today; PR 7 opts in families with a rate today | Families' opt-in rates, and whether the opted-in sample is enough for the operator's comparisons |
| A per-upload "Read as" switch for PDF import: Auto (default), PDF, Images, OCR, Text, greyed out by the route's capabilities (§8.1). **Call by @josh-sanders during development of PR #4440:** yes, on the form and as an optional argument on `import_bank_statement` | How often people override Auto, and with what |
| One way to fit the model for every feature: each item (transaction, text chunk, page image) costed, batches split in half on `ContextTooLong` or an answer cut at the output limit, only a single item that can't fit escalates; no page limit (§8.1). **Call by @josh-sanders during development of PR #4440:** yes; the five-page cap came from #808 sending every page in one request "to avoid token limits"; a per-page OCR price waits for an issue | A stubbed model refusing more than N items, and an answer stopped at the output limit; long statements on small local vision models |
| Health probes as jobs, using each endpoint's timeout (§13). **Call by @josh-sanders during development of PR #4440:** yes, keeping #3155's 60-second cache, 'Run checks again' and 'opening a tab triggers nothing' | A slow local model's probe against #3155's 5-second timeout |
| MCP's two AI tools: move only the model call into a job, the request waiting for the result; the pending import, `get_import_status` and streaming go to the MCP work-pack (§14). **Call by @josh-sanders during development of PR #4440:** yes | MCP clients' timeouts while `import_bank_statement` waits for an extraction |
| Cancelling is cooperative, as in #2685; in chat a stop closes the stream at once, a running tool finishes, the turn ends before the next round (§12). **Call by @josh-sanders during development of PR #4440:** yes | A stopped chat on llama.cpp: the slot freed; a stop during a write tool |
| #4444's typing hold, moved into the gate on local hosts with its 15-minute cap; its after-reply hold dropped (§11). **Call by @josh-sanders during development of PR #4440:** yes | Chats sent during a long prompt read with and without the hold; how often the cap is reached |
| #4237's health signals on the new lane queues: not counted as backed up, `ai_queues_not_polled`, the busy bubble (§11). **Call by @josh-sanders during development of PR #4440:** carry them over | A worker started with the old queue names during the upgrade |
| PR 2 in five parts (2a to 2e), each its own PR into `main`, merged in order, all in one release (§19). **Call by @josh-sanders during development of PR #4440:** yes | Review time per part; `main` green and releasable after each part |
| PR #4440 holds only the proposal documents and stays a draft until the whole plan is done; the spike branch is never merged, and only its report is in PR #4440 (§19). **Call by @josh-sanders during development of PR #4440:** yes | The maintainers' review of PR #4440 and of the first code PR |
| PRs 2a to 2e land in v0.7.7 (§19). **Call by @josh-sanders during development of PR #4440:** yes | Review and merge time for five PRs within one release |
| The order of #3422 (vault statements indexed, `get_document_text`) and PRs 2b and 2e (§5.5). **Call by @josh-sanders during development of PR #4440:** the plan works in either order; the recommendation posted on #3422 is that it lands first, its job on `ai_low_priority`, queued only when a store is configured and the uploader has AI on, and reading PDFs through `Pdf::TextExtractor` | Holdner's and the maintainers' answer on #3422 |
| Indexing stored statements when Documents is turned on (§5.5). **Call by @josh-sanders during development of PR #4440:** yes, from PR 7, with #3422's idempotency key and row lock | A family turning Documents on with statements already in the vault, and `ProcessPdfJob` indexing one at the same time |
| `search_family_files` always listed, falling back to #3422's metadata search with the router's reason when `search_documents` isn't available (§14) | An MCP-only install with no AI searching its vault |
| Turning Documents off deletes the copies already in a cloud store; catching up skips statements whose uploader has the switch off (§5.5) | What family admins expect when they turn Documents off |
| Two-level consent: the family per feature, then the member (§6) | Admins and members trying the AI features page; whether `:no_family_consent` blocks anything people expect to work |
| Config source all or nothing: the UI, `AI_CONFIG` or the old ENV, no per-field locks (§4.1) | Operators of compose, Helm and quadlet installs upgrading with each source |
| One YAML file, `AI_CONFIG`, loaded into the tables at boot (§4.4) | A home-lab and a multi-tenant config written from scratch and exported again |
| The old AI ENV kept for a deprecation period, read as a generated config file (§4.5). **Call by @josh-sanders during development of PR #4440:** yes: warned at every boot, removed in a later release | Every documented ENV setup booting on the new code, compared with today's resolution |
| Cloud endpoints must use https; local ones may use http (§4.2) | Installs whose cloud gateway sits behind plain http on a private network |
| Three protocols: `compatible`, `anthropic`, `jev` (§4.2); a native Bedrock or Vertex AI endpoint (region, IAM or a service account) has none | Bedrock through RubyLLM's native provider and through an OpenAI-compatible proxy, against `AiEndpoint`'s columns |
| Shadow runs for any feature, as their own job (§8.2). **Call by @josh-sanders during development of PR #4440:** yes | A shadow run of `detect_merchants`, with the comparison page |
| Smart-fill and smart-configure become asynchronous (§11). **Call by @josh-sanders during development of PR #4440:** a job and a Turbo Stream; #3202 built them synchronous on purpose, and the dialog, the bounded history and 'nothing applies without the user' stay | Users on a slow local model: a skeleton and a broadcast against today's wait |
| Small batches that re-enqueue at the back of the queue, so families take turns (§11). **Call by @josh-sanders during development of PR #4440:** one batch per job for every install; local presets 10 per call, cloud presets today's 25; local models generally serve one family and cloud models many, so fairness is tested on cloud | Two families' imports on one AI thread: each family's first result time |
| Prompts and models unchanged by this work (§20). **Call by @josh-sanders during development of PR #4440:** every one of today's prompts becomes its own file, word for word (OpenAI's, the simplified one for custom servers, Anthropic's), and the presets name the right one | Sure's recorded evals before and after each PR |
| Ruby ML engines and the classifier settings page left alone (§20) | Nothing in the plumbing; a separate proposal |
| Suggestions instead of AI locks, and rule ordering (§20) | A user review of corrections, and evals of how often AI's answer is overridden |
| Rules that run only after an AI rule (§20) | A prototype on the generation completion hook (§8.1) |
| Family-owned endpoints and models (§20) | A security review of family-set base URLs (internal addresses), and demand on #3037 |
| A member's private accounts sent to background AI (§20) | The consent test with private and shared accounts |
| No `ai_calls` table replacing `llm_usages` (§20) | Partly covered: "RubyLLM's usage ledger" compared RubyLLM's table with `llm_usages`, not an `ai_calls` table |
| Langfuse traces unchanged (§20) | Partly covered: "Tracing modes" |
| The MCP server's renames, shared tool catalog, scopes and family switch (§20) | Partly covered: RubyLLM's MCP client chose Sure's tools with `only` (`ruby_llm_mcp_live_test`) |
| One read-only or mutating classification of each `Assistant::Function` for MCP scopes, MCP annotations and chat approvals, taken from #4628 if it lands first, unclassified meaning mutating (§8.4, §14) | Chat approvals and an `mcp:read` token driven by the same classification; whether any tool needs different answers for the two (`preview_rule`, `search_family_files`) |
| Product features from PR #4440's user review (§20) | Their own proposals |
| New providers only as presets; no model discovery (#3694, §20) | Partly covered: RubyLLM's registry listed a retired model, so a seeded list needs checking |
| Langfuse, Sidekiq and rails-settings-cached stay (§20) | Sidekiq covered ("Job runners and chat priority"); Langfuse partly ("Tracing modes": `metadata` goes to any OTLP backend); rails-settings-cached not |
| What a family's data may be sent as: URLs as attachments, web search in chat, voice | RubyLLM features tested ("RubyLLM 2.1.1 features tested"); no product test |
| Input moderation, masking sensitive values before they leave | `top_secret` and moderation ran (see the ecosystem table); no product test |
| Provider batches for categorizing; caching the tool list | Refused on Gemini's free tier; needs a paid key |
| RubyLLM's durable loop against idempotent write tools | "Durable agents" (docs); Sure's write tools aren't idempotent |
| RubyLLM's evaluations, runtime contracts, provider-level test stubs, a prompt registry | Tested in the ecosystem table; no comparison with Sure's evals on the same features |
| An in-process vector index, in-process inference, a monitoring dashboard | Tested in the ecosystem table; each costs native builds or memory |
| Exact token counting for the history budget | Tokenizers measured against the estimator (12,418 vs 15,085 for the tool list) |
| RubyLLM's generators and coding-assistant skill for contributors | Generators run (`ruby_llm_generators_test`); against Sure's design-system rules |
| RubyLLM 2.2's code execution, skills and chat files | Unreleased; nothing run |

**Technical limits** (as found; each has the workaround noted)
- Gemini's compatible API and llama.cpp reject RubyLLM's PDF `file` part (400); only OpenRouter
  accepts it, and bills parsing even on free models. Workaround: page images or text.
- llama.cpp without a vision projector answers images with a 500. Workaround: check the route's
  `vision` need first.
- Gemini refuses a tool round another model started (400, missing `thought_signature`).
  Workaround: Google's placeholder, or the native provider.
- RubyLLM sends a PDF as a `file` part to every OpenAI-compatible server, so
  `convert_unsupported_attachments` never runs for them.
- RubyLLM downloads non-image URL attachments from the Rails process (`Attachment#fetch_content`).
- RubyLLM's fallbacks can't move between two endpoints of the same provider: `:openai` has one
  `openai_api_base`.
- RubyLLM's fallback by model ID resolves through the registry, so a gateway model outside it
  raises `ModelNotFoundError`; a `RubyLLM::Model` (`Model.default`, `:nodoc:`) works.
- `RubyLLM::ModelNotFoundError` isn't a `RubyLLM::Error`, so a rescue of `RubyLLM::Error` misses it.
- RubyLLM's `input_tokens` excludes cached tokens (reported 512 where the prompt was 12,457).
- RubyLLM retries OpenAI's `insufficient_quota` 429 like a rate limit.
- A claim taken inside a transaction is invisible to other processes until it commits.
- A claim only stops a turn that checks it: a turn whose claim lapsed still ran its write tool
  unless it renewed the claim before the tool run.
- RubyLLM's usage ledger accepts only its own eleven operations, records RubyLLM's provider slug,
  and prices only models in its registry.
- Anthropic checks the balance before the model name, and blocks `count_tokens` without credits.
- `pdftoppm` exits 0 with a 1×1 PNG when it can't allocate a page.
- Active Storage blocks libvips's PDF loader (`Vips.block_untrusted`).
- llama-server drops special tokens (an OCR model's table tags) unless started with `--special`.
- Free tiers: OpenRouter allows 50 requests a day without credits; Gemini's free tier has a
  per-minute cap that a 12-round tool loop exceeds.
- Five ecosystem gems pin RubyLLM 1.x: `ruby_llm-skills`, `-tribunal`, `-top_secret`, `-mcp`,
  `-instrumentation`.
- Fiber workers need `isolation_level = :fiber`: under thread isolation, two jobs on one worker
  read each other's `Current` attributes, so one family's job would see another's. Solid Queue
  checks the setting at boot; Async::Job's railtie sets it for the whole app when it loads.
- `ruby-vips` renders in the worker's own thread: 0.28 s of a 0.33 s render stalled every other
  fiber. `pdftoppm` in a child process stalled nothing.
- A transaction held across an AI call keeps its connection: nine fibers holding one for 2 s ran
  three at a time on a pool of 3.
- llama-server answers queued requests in arrival order, whatever their source, with no request
  priority or preemption; its MTP speculative decoding allows only one slot; its context is
  divided between the slots (65,536 becomes 16,384 each with 4) unless it runs with
  `--kv-unified`, which is off by default when `--parallel` is set. It does stop work on a request
  whose connection closes.
- A slot held in one process doesn't limit another: two workers each admit the server's full size.
- A thread can't be interrupted safely mid-request (`Thread#raise`); a streamed request can, at its
  next chunk. Nothing arrives while the server reads the prompt, and embeddings don't stream.
- Solid Queue's concurrency semaphore expires after `duration` (3 minutes by default), counts jobs
  rather than requests, and takes its key at enqueue, before the router has picked a route.
- Retries don't absorb a provider's concurrency limit: with 20 allowed at once, 80 of 200 calls
  from 50 threads and 160 of 200 from 200 fibers still failed after RubyLLM's 4 attempts.
- RubyLLM has no priority or concurrency limit of its own; Solid Queue's job priority only
  orders claims, so with 50 fibers it changes nothing; Async::Job's executor drops a job's
  exception once Active Job has logged it (read in the source, not tried).

**RubyLLM 2.1.1 features tested** (`ruby_llm_features_live_test`, `ruby_llm_features2_live_test`,
`ruby_llm_mcp_live_test`, `ruby_llm_persistence_live_test`, `ruby_llm_generators_test`;
cassettes under `features/`; Gemini's free tier through Sure's RubyLLM context unless noted)

| Feature | Result | Bears on |
|---|---|---|
| Ask, then ask again | The second request carries the first exchange; the history lives in the `Chat` object, so it ends with the job | Sure stores history |
| Streaming | A block gets the answer in chunks, on any provider | Streaming everywhere (BC4) |
| Files with `with:` | A local image goes as a data URI; an image URL goes to the provider, and Gemini's compatible API refused to fetch it ("Cannot fetch content from the provided URL"); two files at once work; a PDF URL is downloaded by the Rails process (`Attachment#fetch_content`) | Where files may come from (product); provider fetching (limit) |
| Tools, in RubyLLM's loop | `ask` runs them with no code, and with no round cap: 12 calls in 12 requests until the spike's guard | Sure owns the loop |
| Tool approval | `ask` stops before a `requires_approval` tool; `approve`, then `complete` runs it once | Write tools run at once today |
| MCP client | RubyLLM's client reached Sure's own `/mcp` in process (a custom transport), fell back from revision 2026-07-28 to Sure's 2025-06-18, showed only the two tools `only` allows, and Gemini answered with them | Sure is never a client; shared tool catalog out of scope (§20) |
| Structured output | A Schematist class and `response.parsed`; strict `json_schema` only, no fallback chain | The `auto` chain |
| Agents | A `RubyLLM::Agent` class runs in Sure's context; it needs `protocol: :chat_completions` too, or `:openai` calls the Responses API (a bare 404 on Gemini) | One declarative class per feature |
| Fallbacks | A refused `:openai` endpoint fell back to native Gemini inside one chat | Failover policy |
| Cost | Tokens always; a price only for models in RubyLLM's registry (none through the compatible API, $0.0000062 native); a missing price is `nil` | `LlmUsage` and Sure's prices |
| Web search with citations | Refused for quota on every try: not on this free tier | Chat's tools reach only the family's data |
| Batches | 400 "Precondition check failed": Gemini batches need billing; RubyLLM's batches also skip `with_headers` | Interactive fan-out for categorizing |
| Prompt caching | Gemini's explicit cache is capped at 0 tokens on the free tier; Sure's tool descriptions alone were 10,783; Gemini refuses a cache combined with request-level tools | Nothing planned; 12k-token tool list |
| Text to speech | Gemini read a sentence aloud, as 24 kHz PCM | No voice planned |
| Moderation | OpenAI's endpoint answered on the key with no credits (`flagged: false`) | No input moderation planned |
| OCR | `RubyLLM.ocr` is Mistral's or Cohere's; no key | Local OCR route |
| Video | The registry's Veo model is retired; Google's suggested replacement isn't served for `predictLongRunning`, which RubyLLM 2.1.1 calls | None |
| Rails persistence (two models) | RubyLLM's install templates, run in a rolled-back transaction: eight tables; Sure's `messages` would need 11 columns (`role`, `thinking_signature`, `raw_reasoning`, …) and `chats` a model reference. A two-turn chat continued from the database, and each message knew its producer. Once `ruby_llm_usages` exists, a plain chat through Sure's transport writes a usage row | Chat storage; the ledger off |
| Durable agents (docs) | One `step` per job, or one job with Rails 8.1 continuations; `cancel` is stored; execution is at least once, so tools must be safe to run twice | Sure owns the loop; Sure's write tools aren't idempotent |
| Generators | The agent generator binds to an `acts_as_chat` `Chat` and writes ERB instructions under `app/prompts`; the tool generator writes partials with raw Tailwind palette classes (against Sure's design-system rules) that render a `messages/error` partial Sure lacks | Prompts as `.md`; design-system rules |
| AI coding assistants | The gem ships a 106-line `rubyllm` skill that routes an assistant to the guide for each task | Contributor tooling |

**Product decisions these add** (for and against, as above): accept URLs as attachments or not;
web search in chat; input moderation; voice; provider batches for categorizing; prompt caching
of the tool list; approvals for write tools; RubyLLM's durable loop against idempotent tools;
RubyLLM's generators and skill for contributors.

**Technical limits these add:** Gemini's free tier refuses web search, batches and explicit
caching; RubyLLM's registry can list retired models; Gemini's compatible API won't always fetch
an image URL; `:openai` defaults to the Responses API; RubyLLM's usage ledger records every call
once its table exists.

**Evaluations and the ecosystem gems** (`ruby_llm_evaluation_live_test`,
`ruby_llm_ecosystem_test`, `ruby_llm_red_candle_live_test`; tokenizer and `top_secret` in a
Debian container like Sure's image)

| Gem or feature | Result | Bears on |
|---|---|---|
| `RubyLLM::Evaluation` (2.1) | Graded `ExtractBankStatement` on both text layers with Gemini, plus a Ruby reconciliation assertion. BAC passed. The scan failed although the extraction was right: "0 transactions; opening balance nil…" didn't "agree with" the reference wording. A JSON report with tokens and cost | Sure's own evals (about 3,700 lines, `evals:ci_regression`, recorded samples) and the prompt-change gate (O-B3) |
| `ruby_llm-contract` 1.5.0 | A step that validates by reconciling escalated from Lightning's real wrong extraction to the next model, with a trace of both attempts. Its test adapter needs no global hook | Sure's checks plus its JSON-mode chain and router |
| `ruby_llm-test` 0.3.0 | Stubs at the provider, but wraps every provider in the process, so a call with no stub left raises; it can't share a process with recorded tests, so it ran in a child process | Sure's VCR and WebMock tests |
| `ruby_llm-instructor` 0.2.0 | Installs, but reads 1.x's parsed content: every 2.x reply fails "got String" | Structured output |
| `ruby_llm-registry` 0.1.3 | Versions, required variables, ERB rendering; labels resolve through `manifest.yml`, not the front matter its README shows; variable values aren't evaluated, the template body is | Prompts as `.md` with `%{}`, family overrides, locales (§8.3) |
| `ruby_llm-turbovec` 0.1.0 | An index inside the Ruby process, saved to and loaded from a file; needed Rust, `libclang` and OpenBLAS to build | pgvector, Qdrant (§5.5) |
| `ruby_llm-monitoring` 0.4.0 | Its events hold no prompt or answer text (model, tokens, cost, the request URL, provider options). Mounted normally, its initializer deletes RubyLLM's `RubyLLM` acronym and adds `LLM` app-wide, so Zeitwerk would expect `LLMUsage`, `Provider::LLMConcept` and `Settings::LLMUsagesController`, and Sure's `Llm…` classes would stop loading | Tracing modes, `LlmUsage` |
| `ruby_llm-red_candle` 0.2.1 | Installs (`< 3.0`) but fails to load: `RubyLLM::Model::Info` is gone in 2.x. Red Candle itself ran Qwen2.5-1.5B inside the test process: +2,017 MB memory, 38 s for a wrong bill setup on CPU (load 321 s with download) | Local inference as a server (§4.2) |
| `ruby_llm-tokenizer` 0.1.2 | Needs the system `libsentencepiece` (Debian has it, openSUSE doesn't). Sure's 34 tools: 10,737 tokens (Qwen), 10,691 (GPT-4o), against `TokenEstimator`'s 15,085 and llama.cpp's 12,418 with the chat template. Its bundled Gemini model fails to load | History budget from the model's window (§8.4) |
| `top_secret` 1.0.1 (under `ruby_llm-top_secret`) | Regex filters masked a card, an email, a phone number and an SSN, and restored exactly; the account number, name, towns and amounts passed through. With MITIE's 345 MB NER model it also masked the name ("JohnSmith", 1.4 s) but not the towns in the OCR'd text, nor the account number. NER configured after a first filter in the same process is ignored: the configuration is fixed at first use | What family data reaches a provider |
| `ruby_llm-skills`, `-tribunal`, `-top_secret`, `-mcp`, `-instrumentation` | Pinned to 1.x. MCP and instrumentation are built into 2.1 (tested above); skills (`SKILL.md` as a tool) has no 2.x equivalent; tribunal's evals overlap `RubyLLM::Evaluation`; top_secret's filter is tested directly | Ecosystem churn after 2.0 |

**Product decisions these add:** adopt RubyLLM's evaluations beside or instead of Sure's;
runtime contracts with escalation; provider-level test stubs; a prompt registry with versions
and labels; an in-process vector index; a monitoring dashboard; in-process inference; exact
token counting for the history budget; masking sensitive values before they leave.

**Technical limits these add:** two gems install beside 2.1.1 and fail on 2.x
(`instructor`, `red_candle`); `ruby_llm-test` wraps every provider in the process;
`ruby_llm-monitoring` rewrites app-wide inflections; native gems need Rust, `libclang`,
OpenBLAS and `libsentencepiece` in Sure's image; RubyLLM 2.x registers `RubyLLM` as an
acronym itself.

## The external assistant (agent mode), outside the criteria

Today's `Assistant::External::Client` (141 code lines) speaks plain OpenAI chat completions over
SSE. Its extras are the `X-Agent-Id` and `X-Session-Key` headers, `user: "sure-family-<id>"` in
the body, the history with no tools, and a full `…/chat/completions` URL. Over RubyLLM that's 10
adapter lines on `Compatible`. `agent_test` covers it with stubs, and `agent_live_test` runs it
live against OpenClaw 2026.10.8, whose default agent ran on the llama.cpp server.

- **Headers:** `Chat#with_headers`, from the endpoint's `agent_settings`.
- **The family as `user`:** through `with_provider_options`. RubyLLM's `with_end_user` sends
  `safety_identifier` to the `:openai` provider (`protocols/chat_completions/chat.rb:395-399`),
  which an agent wouldn't read.
- **The URL:** the normaliser strips a trailing `/chat/completions`.
- **Errors and retries:**
  - **Errors:** a refused connection is `Unreachable`, a 502 is `Upstream` (stubbed), and a wrong
    gateway token is `Unauthorized` after one attempt (live).
  - **Retries:** with `max_retries` set on the endpoint, a failed connection is retried before
    the stream starts and never after it, which is what today's client does by hand.
  - **Usage:** OpenClaw sends a usage chunk of zeros, so it comes back as zero tokens.
- **`stream_options` is fine:** RubyLLM always adds `stream_options: {include_usage: true}`, which
  today's client doesn't send. OpenClaw accepts it and answers with the usage chunk.
  `agent_live_test` (live, `openclaw/converse`) streams an answer that depends on the history
  ("Biscuit").
- **Sure's agent headers are ignored, today too.** OpenClaw reads `x-openclaw-agent-id` and
  `x-openclaw-session-key` ([its docs](https://docs.openclaw.ai/gateway/openai-http-api)), not
  `X-Agent-Id` and `X-Session-Key`. Checked live with `openclaw sessions --json`: a request with
  `X-Session-Key: agent:main:main` and `user: "sure-family-spike"` was stored as
  `agent:main:openai-user:sure-family-spike`, and a request with
  `x-openclaw-session-key: agent:main:sure-spike-header` as that key. So every chat in a family
  shares one agent session, keyed by `user`. OpenClaw's docs advise against account-level `user`
  values for that reason. This is in today's client on `main`, not something RubyLLM changes.
- **Speed:** the first request to a new OpenClaw install took four minutes (its first agent run
  on a large system prompt); later ones took about three seconds. A second fresh install, for the
  proxy run, took 27 seconds, so four minutes isn't typical. Today's client times out after
  120 seconds.
- **`Assistant::External::ModelCatalog`** (63 lines, `GET /models`) is deleted by the plan
  (section 8.4), so it wasn't ported.

## Local servers in containers

The test host has no discrete GPU, so Ollama and LM Studio ran on its CPU (20 cores) with
`Qwen3-30B-A3B-Instruct-2507-Q4_K_M` from local GGUF files: about 7 seconds for a bill setup and
30–45 seconds for a two-round tool turn. Each ran alone, as a rootless container with host
networking and the server bound to 127.0.0.1, and was removed afterwards.

- **Ollama 0.40.12** (`docker.io/ollama/ollama`): the GGUFs imported with `ollama create`, which
  took the chat template from the file and reported the `tools` capability. Strict schemas are
  accepted. Embeddings work with `granite-embedding-small-english-r2` (384 dimensions).
- **LM Studio** (llmster 0.0.25, llama.cpp engine 2.41.0): no official image, so a small Ubuntu
  image runs LM Studio's installer; the GGUF is imported with `lms import --symbolic-link` (the
  default moves the file) and loaded with an 8,192-token context. **It answers a request for a
  model it doesn't have with the model it has loaded** (200, the response names the loaded
  model), so a mistyped model name never fails there.
- **OpenClaw 2026.10.8** (`ghcr.io/openclaw/openclaw`): the chat-completions endpoint switched on,
  token auth, loopback bind, and an `openai-completions` provider pointing at llama.cpp. Its keys
  come from env through OpenClaw's secret references, not the config file.
- **VCR:** Sure's setup ignores localhost, so `with_spike_cassette` records it inside its block.
  Addresses and tokens are filtered like the others.
- **A one-off LM Studio failure:** during the proxy run, two of 36 requests failed in 0.2 seconds
  with LM Studio's own "Channel Error … Engine protocol predict request failed: fetch failed",
  each the request straight after a streamed reply. Sure mapped them to `Refused`, so
  they weren't retried. Twelve stream-then-request pairs straight afterwards all succeeded, and
  the cause wasn't found.

## The proxy with local servers

`test/models/ai/live/container_proxy_check.rb` ran every client against each container through
the logging forward proxy, with the server addressed as `127.0.0.1` and as `localhost`:
generate (RubyLLM and hand-written), a streamed converse, embeddings on Ollama, and on OpenClaw
both the spike's agent converse and `Assistant::External::Client` from `main`.

- **Every call worked through the proxy, and streaming isn't buffered:** 39 chunks over the same
  two to three seconds direct and proxied. All the spike's clients agree on every scenario, since
  they share `Ai::Transport::Http.proxy_for`.
- **Sure proxies loopback.** With `HTTPS_PROXY` or `HTTP_PROXY` set and no `NO_PROXY`, requests
  to `127.0.0.1` and `localhost` went to the proxy. Ruby's own lookup (`URI#find_proxy`, which
  Net::HTTP and Faraday use when given no explicit proxy) returns no proxy for loopback, but
  `proxy_for` hands Faraday an explicit one. Through the local test proxy that worked; through a
  proxy on another host, `127.0.0.1` would be that host's loopback, and an egress proxy that
  refuses private addresses would refuse it. The plan's resolver (section 7) should skip loopback
  as Ruby does.
- **`NO_PROXY` matches the host as written.** `127.0.0.1` and `127.0.0.0/8` bypass the proxy for
  `http://127.0.0.1:…` but not for `http://localhost:…`, and `localhost` only for `localhost`.
  The settings page should say so.
- **`main`'s `Assistant::External::Client` resolves the proxy differently.** It reads only the
  URL scheme's own variable, so with only `HTTPS_PROXY` set it goes direct to an `http://`
  gateway where the spike's clients go through the proxy. It matches `NO_PROXY` by name or suffix
  only: with `HTTP_PROXY` and `NO_PROXY=127.0.0.0/8` it still sent `127.0.0.1` to the proxy.
  Moving the agent onto the shared transport gives it the same rules as every other client.

## OpenRouter chat on free models

The key has never bought credits, so `openrouter_chat_live_test` uses `:free` models. They run
through RubyLLM's `:openrouter` provider, with Sure's app headers.

- **Bill setup in strict mode works on both transports** with `recursive/flint-v1.0:free`. Flint
  lists `response_format` but not `structured_outputs`, and the answer still parsed. OpenRouter
  also took a strict schema for `nvidia/nemotron-3.5-lightning:free`, which lists neither. It
  doesn't reject parameters a model lacks (unless the request sets `provider.require_parameters`),
  so a strict request there isn't proof the schema was enforced. Sure's parser is what makes
  these work.
- **A streamed tool round works** on Nemotron 3.5 Lightning: `get_accounts` on round one, run by
  Sure, and the answer streamed on round two. **Round two sends the model's `reasoning_details`
  back**, the live counterpart of the stubbed Gemini test, and the reason the preset uses the
  `:openrouter` provider.
- **Errors:** the paid `nvidia/nemotron-3.5-lightning` answers 402 "Insufficient credits", which
  maps to `Refused` after one request even with `max_retries: 2`. A wrong key is `Unauthorized`.
  `xingchen-agi/xing4.0-29b-a4b:free` answered 429 "temporarily rate-limited upstream" three
  times in a row, which maps to `RateLimited`; it recovered before a cassette could catch it.
  Free models share an upstream pool, so a route that relies on one needs a fallback.
- **Free models reason at length, and effort `low` barely helps.** One bill setup, reasoning
  tokens, one run each:

  | Model | Default | `low` (RubyLLM, hand-written) | `none` |
  |---|---|---|---|
  | Nemotron 3.5 Lightning | 1,517 | 1,449, 1,809 | 0 (112–116 tokens in all, answer correct) |
  | Flint 1.0 | 519–1,077 | 572, 778 | 400 "Reasoning is mandatory for this endpoint and cannot be disabled." |

  Both transports' forms reach the model: RubyLLM sends `reasoning: {effort:}` and the
  hand-written one a top-level `reasoning_effort`. So `none` is the setting that saves tokens, on
  the models that allow it. OpenRouter's own switch, `reasoning: {enabled: false}` in the
  endpoint's `extra_body`, behaves the same on both models and both transports: Nemotron 0
  reasoning tokens (116–119 in all, answer correct), Flint the same 400. On OpenRouter a route
  needs no separate on/off setting; effort `none` covers it. The local servers differ; see
  "Turning reasoning off, server by server". Where a model refuses it, a strict route gets `Refused` with that
  message; an `auto` route would read the 400 as a JSON-mode rejection, drop the effort with
  `response_format` and retry (`JsonMode`, not run live), which works but blames the wrong thing.
  Section 7 should let a route's effort be checked like its JSON mode, and the routes need a
  `max_output_tokens` well above the answer's size.

## Turning reasoning off, server by server

`reasoning_switches_live_test` sends each setting in strict mode with both transports, so a
refusal would surface. The test host's llama.cpp server runs with thinking off, so its rows force it
on with `chat_template_kwargs: {enable_thinking: true}` first. Ollama 0.40.13 ran in a temporary
container with Qwen3.6-35B-A3B and gpt-oss-20b from local GGUFs. Completion tokens per bill
setup, one run per transport; the OpenRouter rows from "OpenRouter chat on free models" count
reasoning tokens.

| Setting | llama.cpp, Qwen3.6 | Ollama, Qwen3.6 | Ollama, gpt-oss | OpenRouter, Nemotron | OpenRouter, Flint |
|---|---|---|---|---|---|
| Default | 1,659–2,106 | 1,946–2,199 | 186–215 | 1,517 | 519–1,077 |
| Effort `low` | Ignored | Ignored | Shorter (151–176), and one field missed per run | About the same | About the same |
| Effort `none` | Ignored | **Off** (134–137) | Ignored | **Off** | 400 |
| `reasoning: {enabled: false}` | Ignored | Ignored | Ignored | **Off** | 400 |
| `thinking_budget_tokens: 0` | **Off** (133–134) | — | — | — | — |

- **Ignored means accepted without an error.** Only OpenRouter refuses a setting a model can't
  honour, so a health check can't tell from the status whether a setting worked; it has to
  look for reasoning in the answer.
- **There's no one switch.** Effort `none` works on OpenRouter and on Ollama's hybrid models.
  llama.cpp ignores the OpenAI-style settings and needs its own `thinking_budget_tokens: 0` or
  `chat_template_kwargs: {enable_thinking: false}`. Section 7 should map a route's effort `none`
  per preset (llama.cpp to those fields) rather than send `reasoning_effort` everywhere.
- **gpt-oss can't stop reasoning** but reasons briefly anyway. At effort `low` it lost a field
  in each run: one left the category null ("no category matches Netflix"), the other the name.

## Anthropic and OpenAI on keys without credits

### Anthropic

`anthropic_live_test`, cassettes under `anthropic/`, model `claude-haiku-5-5`.

- **What answers.** `GET /v1/models` answers 200 with the model list. Every request that
  reaches a model gets a 400 `invalid_request_error`, "Your credit balance is too low to access
  the Anthropic API", not a 402. That includes `/v1/messages/count_tokens`, which is otherwise
  free, so the spike couldn't use it to check the request bodies RubyLLM builds.
- **The balance is checked first.** An unknown model name gets the same 400, so a health check
  on such a key can't tell a bad model name from an empty balance. Nor do these runs validate
  the bodies: the forced tool, the streamed tool round and the PDF document block are still
  judged from stubs.
- **Both transports map it to `Refused`, after one request,** with `max_retries: 2`. RubyLLM
  recognises the message and raises `PaymentRequiredError`
  (`transport/error_middleware.rb:98`); the `anthropic` gem raises a plain `BadRequestError`.
  Sure's adapter then flattens both to `Refused`. This is the case where section 9 should give
  an empty balance its own error: RubyLLM already tells it apart, the hand-written transport
  would have to match the message, and a 400 alone looks like a refusal of the request.
- **A wrong key** is a 401 → `Unauthorized` after one request on both transports.
- **The streamed chat turn** sends `stream: true` and the `get_accounts` tool, and gets the
  same 400 before any chunk.

### OpenAI

`openai_live_test`, cassettes under `openai/`, model `gpt-5-mini`, with a new `openai` preset
(`responses_api: true`).

- **What answers.** `GET /v1/models` and listing vector stores answer 200. Chat completions,
  the Responses API and embeddings answer **429** `insufficient_quota`, code
  `credit_balance_exhausted`: "You have no credits remaining." There's no `Retry-After`.
- **RubyLLM retries it.** With `max_retries: 2`, RubyLLM sent each request three times, on
  chat completions, the Responses API and embeddings. Its only payment pattern is Anthropic's
  "credit balance is too low", so OpenAI's spent balance is an ordinary `RateLimitError`.
  `ruby-openai` doesn't retry, so the hand-written transport sent one.
- **Both become `RateLimited`,** which section 9 treats as retryable, with failover and a key
  mark. For a spent balance that's half right: the key mark and failover help, and the retries
  can't. With RubyLLM's own retries plus a job's, one categorization run would repeat requests
  that can't succeed until someone adds credit.
- **For the plan:** give an empty balance its own error, as the Anthropic case already asks.
  Here Sure has to recognise it itself: `insufficient_quota` in the error body, or the message,
  then stop retrying. RubyLLM gives no hook before its retry middleware, so either
  `max_retries` stays 0 for OpenAI and Sure retries, or the spent balance costs two wasted
  requests a call.
- **A wrong key** is a 401 → `Unauthorized` after one request on both transports.
- **Vector stores work on this key:** see the next section.

## OpenAI vector stores with the sample statements, outside the criteria

Vector stores stay on `ruby-openai`: RubyLLM has no vector store calls. The spike ran Sure's own
`VectorStore::Openai` live, on the key with no credits, with the two sample statements
(`test/models/vector_store/openai_live_test.rb`, cassette `openai/vector_store_statements`). It
created a store, uploaded both PDFs, polled until OpenAI had indexed them, ran three searches,
then called Sure's `remove_file` and `delete_store`. At the end it deleted everything it had
created.

- **No credits needed.** Creating, uploading, indexing and searching all answered 200 on a key
  whose chat, Responses and embedding calls get a 429. So a document search that works says
  nothing about whether chat on the same key will.
- **Indexing is asynchronous, and Sure doesn't wait.** Attaching a file answers `in_progress`;
  each statement took about three polls, around 6 seconds, to reach `completed`.
  `Family#upload_document` records the document as `ready` as soon as the upload returns, so a
  search in that window finds nothing, and a file that fails to index stays `ready` too.
- **A scan indexes as empty, without an error.** The scanned Impact statement finished
  `completed` with `usage_bytes: 0` and no `last_error`. OpenAI's file search reads text layers
  only, so the statement can't be found. Sure can tell, from `usage_bytes` or the text layer it
  can already read with `pdf-reader`, and should say so instead of showing it as ready.
- **Every search returns something.** The BAC statement is a single chunk. It came back for all
  three queries:
  - "monthly apartment rent payment", at score 0.84;
  - "payroll preauthorized credit", at 0.14;
  - "check 1239 amount", at 0.17.

  The last two answer from the scan's lines, which aren't indexed. Neither OpenAI's search nor
  `SearchFamilyFiles` applies a score threshold, so chat gets the wrong statement as context for
  a question about the other one.
- **Results name Sure's temp file.** `upload_file` uploads a `Tempfile`, so OpenAI stores and
  returns names like `bac_ocr20261029-2988578-6rl3ct.pdf`, and `SearchFamilyFiles` passes that
  name to the model. Uploading with the original filename, or mapping `file_id` back to
  `family_documents`, would fix it.
- **Removing doesn't delete.** Sure's `remove_file` only detaches a file from the store, and
  `delete_store` deletes the store but not its files. After both had succeeded, both statements
  were still in OpenAI's Files API (`GET /v1/files/{id}` answered 200) until the spike deleted
  them. Nothing in the app calls `remove_document`, and `delete_store` runs only when saving the
  store's id fails. So every statement a family uploads stays on OpenAI after it's removed, and
  after the family is deleted.
- **It skips Sure's HTTP stack.** `VectorStore::Openai` builds its own `OpenAI::Client`, without
  `Ai::Transport::Http`'s proxy, TLS settings and headers.
- **For the plan** (section 5.5, the `embed` route with `vector_store`):
  - wait for indexing, and record `failed`, and an empty index, as the document's status;
  - delete the file from the Files API when a document, or the family, goes;
  - keep the original filename;
  - set a score threshold for `search_documents`;
  - build the client through `Ai::Transport::Http`.

## Jev: hand-written, RubyLLM or a Jev gem, outside the criteria

The plan keeps the Jev transport hand-written. Its wire code in `Provider::Jev` (the request,
retries, parsing and usage) is 72 code lines, with 444 lines of tests. The spike checked two
replacements: RubyLLM's `judge`, and `ruby_decision_model`, the most-starred Ruby client for
decision models (59 stars, 20,528 downloads, 0.3.0 from 2026-10-12, no runtime dependencies,
"API may change").

**RubyLLM's `judge`.**

- **OpenCode Zen works on 2.1.1** (`https://opencode.ai/zen/v1/systemone`, `jev-1.13-free`,
  anonymous key `public`). RubyLLM's `typesafe` provider sends Jev's System One payload and
  parses all three answer types (`judge_jev_live_test`, live, `jev/judge_ruby_llm`). A made-up
  key gets 401, mapped to `UnauthorizedError`.
- **OpenRouter doesn't work on 2.1.1, and does on `main`.** 2.1.1 posts to `<base>/v1/systemone`,
  a 404 on OpenRouter, and its OpenAI Decisions payload gets a 400 (`openrouter/judge_ruby_llm`).
  [#1264](https://github.com/crmne/ruby_llm/pull/1264), merged on 2026-10-26 and not yet
  released, adds OpenRouter judgments as a dialect of System One posting to `alpha/decisions`,
  with OpenRouter's reported cost. Judged from the PR and source only: running unreleased code
  from GitHub was blocked in this session, and OpenRouter's Jev models are paid.
- **Paths are still fixed per provider on `main`:** `<base>/v1/systemone` for TypeSafe-style
  servers, `systemone` for Ollama, `../alpha/decisions` for OpenRouter. A gateway at any other
  path can't be reached; Sure's `JEV_ENDPOINT` takes any full URL.
- **No batching or concurrency for judgments.** RubyLLM's batch API covers chats and embeddings
  only, and its fiber concurrency is for tool calls. No issue or PR asks for either.
- **Packing works, with no helper.** `judge` takes any Hash as the state and any number of
  questions, so Sure builds the packed state and one `choice` per transaction itself, and reads
  the answers back by name. Eight transactions in one request: all eight right, 1,016 input
  tokens (`judge_jev_live_test`, live, `jev/judge_ruby_llm_packed`). The questions have to go in
  `questions:` per call; a `RubyLLM::Judge` subclass declares a fixed set.

**The `ruby_decision_model` gem** (`Provider::JevGem`, 54 code lines, replacing the 72).

- It takes over only `decide!`. Everything above the wire stays Sure's: the fan-out, the
  category criteria, the opt-out sentinel and the confidence rules.
- **Sure's 30 Jev tests pass against it, with four overridden** (`jev_gem_test`). All four are
  one difference: the gem rejects a whole response for one malformed answer (a choice or score
  without a confidence, a noul outside 0..1), where Sure keeps the answer with a confidence of 0.
  In Sure's fan-out that rejection would fail every transaction in the batch, so the adapter
  rescues it and withholds only the malformed answer. Only the error message tells that case
  apart from an unparseable body, and the request's usage is lost with it.
- **The adapter has to bring its own transport and URL handling.** The gem's `Net::HTTP` ignores
  Sure's custom CA settings and opens a new connection per request; the adapter injects a Faraday
  transport. The gem appends a fixed path to a base URL, so the adapter subclasses its System One
  provider to post to Sure's full URL.
- **Live on OpenCode Zen** (`jev_gem_live_test`): four transactions categorized correctly through
  `auto_categorize`'s fan-out, and a 401 that isn't retried.
- **It brings** vendor providers Sure doesn't have (OpenAI Decisions, Cloudflare Clef, Perplexity,
  Databricks), retries that honour `Retry-After`, and a request id per response.

**The fan-out is Sure's in every design.** Jev takes one state per request; nothing documents a
multi-state request, and other clients fan out on their side (go-jev's `Map` runs four at a
time). Neither RubyLLM nor the gem fans out, so the batching code is the same whichever client is
underneath, and isn't a reason to keep the wire code hand-written.
`test/models/ai/live/jev_fanout_check.rb` timed 16 easy transactions on OpenCode Zen, one run
each:

| | Concurrency 1 | 4 | 8 | 16 |
|---|---|---|---|---|
| Hand-written, new connection per request | 11.44 s | 3.25 s | 1.73 s | 0.80 s |
| Gem, new connection per request | 11.70 s | 3.14 s | 1.78 s | 0.87 s |
| Gem, kept-alive connection per thread | 6.07 s | 1.82 s | 1.16 s | 0.95 s |

| Packed (gem, kept-alive) | Requests | Time | Input tokens | Right |
|---|---|---|---|---|
| One transaction per request (above) | 16 | 0.80–11.70 s | 6,405 | 16/16 |
| 4 per request, in parallel | 4 | 0.89 s | 3,227 | 16/16 |
| 8 per request, in parallel | 2 | 0.78 s | 2,711 | 16/16 |
| 16 in one request | 1 | 2.83 s | 2,453 | 16/16 |

- **The two clients are equally fast.** The time is the network's.
- **Concurrency scales almost linearly to 16** on this gateway; Sure's default is 8.
- **Reusing connections halves the serial time,** because each request otherwise does a TLS
  handshake. Sure's Faraday client doesn't reuse connections either; a persistent adapter would.
- **Packing is the biggest tuning lever:** several transactions in one state, one `choice`
  question each. Eight per request used 58% fewer input tokens, because the category list is
  sent once per request instead of once per transaction, at the same speed and accuracy. Jev
  bills input tokens only. One request with all 16 was slower. Accuracy was measured on easy
  transactions only; packing could let one transaction's details sway another's answer, so an
  eval should check it before Sure relies on it.

**So the choice is about the 72 lines, not the fan-out.** The gem saves 18 lines for a second
dependency at 0.3.0 with one semantic difference to paper over. RubyLLM's `judge` adds no
dependency once a release carries #1264, but can't reach a gateway at an arbitrary path. Either
way the fan-out, packing and connection reuse are Sure's to tune.

- **A 402 maps to `Ai::Error::Refused`** (`RubyLLM::PaymentRequiredError`). Section 9 doesn't
  name it, but an empty balance is a key's state, like a 401, not a refusal of one request.

## RubyLLM running Sure's tools, outside the criteria

The plan keeps the tool loop in `Ai::Conversation`. RubyLLM 2.1 lets a caller step its loop:
`Chat#generate` makes one model call and `#run_tools` runs the pending tool calls, both public.
So Sure can keep the loop and its bounds while RubyLLM runs the tools. The spike tried that.

- **The pieces:**
  - `Ai::Conversation::RubyLlmLoop` (35 code lines) steps the loop.
  - `Ai::Conversation::SureTool` (18 lines) wraps each `Assistant::Function` as a
    `RubyLLM::Tool`. It still calls the function through `Assistant::FunctionToolCaller`, so a
    tool's failure is still Sure's data: a not-found has no SQL in it, and the retry hints stay.
  - The compatible transport adds `tool_chat`, `tool_round` and `history` (36 net lines).
  - Total: about 89 lines, against the 9 lines of `run_tools` in Sure's own 47-line loop.
  - Compatible transport only; the Anthropic transport wasn't adapted.
- **The bounds hold:**
  - at most `max_tool_rounds` model calls, the last with `tool_choice: none`;
  - one deadline for the turn, checked while streaming and now also before each tool (a
    `before_tool_call` callback);
  - a cancel checked at the same points stops the turn before a tool runs;
  - one `converse.ai` event per round, as before.
- **What it gains, live on llama.cpp** (`ruby_llm_loop_test`, cassettes `llama_cpp/loop_*`):
  - **Approval for write tools.** `requires_approval` with a resolver that reads Sure's own
    record of the decision. Undecided: the turn ends `:awaiting_approval` with the history so far
    (user, then the assistant's `create_tag` call), and no tag is created. A later `respond`
    with that stored history, after approval, runs `create_tag` and the model confirms. After a
    denial, RubyLLM sends `{"error":"The user denied the create_tag tool call."}` and the model
    says it didn't create the tag.
  - **Tools in parallel** (`concurrency: :threads`). Qwen3.6 asked for `get_accounts` and
    `get_categories` in one round, and both ran off the job's thread. RubyLLM wraps each thread
    in the Rails executor, so each checks out its own database connection and starts with empty
    `Current` attributes. Sure's tools take the user as an argument and don't read `Current`.
  - **Resume after a dead worker.** A history ending with a tool call and no result runs that
    call first, then asks the model.
  - **`tool_call.ruby_llm` events** with the tool's name, arguments and result, in Sure's process.
    Sure's Langfuse subscriber listens only to `*.ai`, so they go nowhere unless Sure subscribes.
  - On OpenRouter Nemotron, RubyLLM keeps `reasoning_details` between rounds itself
    (`openrouter/loop_tool_round`). Sure still stores it, through `provider_state`, for the next
    turn.
- **What Sure still has to build:**
  - **Which tools write.** Nothing marks them, so the spike goes by name: anything not starting
    with `get_`, `list_`, `search_` or `preview_`. That's 19 of the 34 tools. An explicit flag on
    `Assistant::Function` is needed either way, for MCP's `destructiveHint` too.
  - **The decision and the paused turn**, in Sure's own tables, plus the approve and deny UI.
  - **Rounds across a pause.** A resumed turn starts a fresh round budget unless Sure carries
    the count over.
- **The tool list is big.** Sure's 34 tools (without preview features) add 12,418 prompt tokens
  to every round on Qwen3.6: 12,457 with the tools against 39 without
  (`llama_cpp/loop_tool_list_tokens`). That's a fifth of a 64k context before any history.
  llama.cpp caches most of it between rounds, so time suffers less than context does. RubyLLM's
  tool search (`defer:`) only works natively on Anthropic and OpenAI's Responses API; every other
  server gets the whole list. RubyLLM's `input_tokens` left the cached part out here and reported
  512, the usage-count difference listed under "What to watch on upgrade".
- **Verdict:** it isn't a line saving; it's a feature trade. If Sure wants approvals or parallel
  tools, RubyLLM's `run_tools` brings them working, on its public API, for about 40 more lines
  than Sure's own loop. Without those features, Sure's loop is shorter and doesn't depend on
  RubyLLM's tool semantics, such as its denial message and its unknown-tool error, which lists
  every tool name.

## Switching providers partway through a chat, outside the criteria

A chat changes provider when a family changes its chat model, when routing differs by task, or
on a failover. Sure stores the history and rebuilds RubyLLM messages from it each turn, carrying
each message's `provider_state`: Gemini's thought signatures, reasoning text and
`reasoning_details`. `provider_switch_live_test` (cassettes under `switch/`) ran Gemini
(`gemini-3.5-flash-lite`, effort low) against gpt-oss-20b on the test host's llama.cpp, which always
reasons, in both directions. The test covered two cases:
- **Across turns:** turn 1 runs a tool round on provider A, then turn 2 runs on B with A's stored
  history.
- **Mid-turn:** A asks for `get_accounts`, Sure runs it, and B answers. That's a failover between
  rounds, or a turn resumed on another route.

Nemotron on OpenRouter wasn't run: the key had used its 50 free requests for the day.

| Variant | Across turns, both ways | Mid-turn, Gemini → gpt-oss | Mid-turn, gpt-oss → Gemini | Sent to the second provider |
|---|---|---|---|---|
| Today | Works | Works | **400** "Function call is missing a thought_signature" → `Refused` | Gemini's `extra_content` to llama.cpp; gpt-oss's `reasoning` and `reasoning_content` to Gemini, both ignored |
| Producer restored | Works | Works | **400**, the same | Nothing foreign |
| Google's placeholder signature, compatible API | — | — | Works | gpt-oss's reasoning, ignored |
| RubyLLM's native Gemini provider | Works (gpt-oss → Gemini) | Works | Works | Native Gemini sent its `extra_content` and `reasoning_signature` to llama.cpp, ignored |

- **Leftovers travel, but here they did no harm.** RubyLLM 2.1 drops another provider's native
  content only when a message carries RubyLLM's usage record of who produced it. "A message with
  no known producer replays as it is" (`lib/ruby_llm/protocol.rb:589-597`), and Sure's rebuilt
  messages have none. So gpt-oss's reasoning text went to Google, and Gemini's signatures went to
  llama.cpp. Both providers ignored them. Still, a local model's reasoning, which can quote the
  family's data, is sent to a cloud provider that never needed it.
- **What breaks is Gemini continuing another model's tool round.** Gemini checks the signature on
  the current turn's function calls. A call gpt-oss made has none, so it gets a 400, which
  section 9 treats as `Refused`. Across turns it doesn't matter, because Gemini checks only the
  current turn.
- **Restoring the producer** is what RubyLLM's own history would do: each rebuilt assistant
  message gets a `usage_entries:` record of the provider and model that made it, stored in
  `provider_state[:producer]`. RubyLLM then strips every foreign field. It doesn't fix the 400:
  the placeholder lives in RubyLLM's native Gemini protocol, not in the history. It also uses
  RubyLLM's private API (`Message.new(usage_entries:)` and `Accounting::Usage::Entry`, both
  `:nodoc:`).
- **Google's placeholder fixes the 400 on the compatible API.** Google documents
  `skip_thought_signature_validator` for a call Gemini didn't make, and RubyLLM's native Gemini
  protocol sends it (`protocols/gemini/tools.rb:15`). Sure setting it on the first tool call of a
  rebuilt round worked on the OpenAI-compatible API too. The same value went out in the native
  run.
- **RubyLLM's native Gemini provider** handled every case without Sure's help. Moving off
  Google's OpenAI-compatible API would change the plan's Gemini preset (section 4.2). The
  compatible API is what makes Gemini one more compatible server today.
- **RubyLLM's own chat history,** `acts_as_chat`, `acts_as_message` and its tables, would carry the
  producer for free. Judged from its 2.1.1 install templates rather than run, because it needs
  migrations:
  - `messages` needs `role`, `thinking_text`, `thinking_signature`, `raw_content`, `raw_reasoning`,
    `citations`, `server_tool_calls`, `finish_reason` and `cache_until_here`. Sure's are
    single-table-inheritance `UserMessage` and `AssistantMessage` with `status` and `ai_model`.
  - `chats` needs a not-null `ruby_llm_model_id`, pointing at a `ruby_llm_models` registry table.
    Sure's router picks the model per turn.
  - Tool calls go in `ruby_llm_tool_calls`, beside Sure's `tool_calls`.
  - The producer comes from the `ruby_llm_usages` ledger, the table this note says not to create,
    because RubyLLM records usage on every call once it exists.

  That's a redesign of chat storage and of who runs the loop, not an adapter fix.
- **For the plan:**
  - Store each assistant message's producer: route, endpoint and model. Section 8.4 already
    stores the serving route on the message.
  - Drop `provider_state` when the next turn's endpoint or model differs. That's Sure's own
    version of RubyLLM's rule, with no private API.
  - On a Gemini route, give a foreign tool call Google's placeholder signature, so a turn can
    continue on Gemini after a failover or a resume.
  - Choose between those two and RubyLLM's native Gemini provider; RubyLLM's history isn't worth
    adopting for this alone.
  - The spike's `restore_producers` and `gemini_placeholder` switches on
    `Ai::Transport::RubyLlmAdapter` are off by default.

## Bank statements as PDFs (`extract_pdf`), outside the criteria

The plan moves PDF import onto `Ai::Generation` in PR 2, so the statement's file goes through
RubyLLM's `generate`. Today Sure prepares it differently per provider:
- the OpenAI path sends the text layer from `Pdf::TextExtractor`, then for a scan the first five
  pages as images rendered by `pdftoppm`;
- the Anthropic path sends the PDF itself.

The spike sent `Ai::Generations::ExtractBankStatement` three ways: the text layer, the PDF as
RubyLLM's file part, and page images at 150 dpi, as Sure renders them. `Pdf::PageImages` renders
the pages through `ruby-vips` (see "Rendering pages: pdftoppm today, ruby-vips in the spike" below). Super VL's two image
cassettes hold the `pdftoppm` renders of the first run, because its re-run hit OpenRouter's
daily limit for free models. Gemini read both renders identically.

It used two public sample statements (`test/fixtures/files/statements/`):
- **BAC:** one page, with a machine-OCR'd text layer full of errors (`£44.079.83`, words run
  together) and 13 transactions. Its own "Total money in" is wrong by £1.
- **Impact:** two pages, a scan with no text layer. It lists the same 21 transactions twice, by
  date and then by type, and the two pages disagree on one of them.

Results are scored on date and signed amount. "Reconciles" means the opening balance plus every
transaction makes the closing balance. Tests: `extract_statement_live_test`, cassettes under
`statements/`.

| Server (model) | Text layer | PDF as a file part | Page images |
|---|---|---|---|
| llama.cpp (Qwen3.6, no vision) | BAC 13/13, reconciles. Scan: empty, as the prompt asks | 400 "unsupported content[].type" → `Refused` | 500 "image input is not supported" → `Upstream` |
| Gemini (`gemini-3.5-flash-lite`, compatible API) | BAC 13/13, reconciles. Scan: empty | 400 "Invalid content part type: file" → `Refused` | BAC 13/13 and scan 21/21, both reconcile, no duplicates |
| OpenRouter Nemotron Lightning (text only, effort none) | BAC 9/13 and 4 wrong; doesn't reconcile | Free `pdf-text` engine: BAC 2/13; scan: empty | 404 "No endpoints found that support image input" → `Refused` |
| OpenRouter Nemotron Super VL (vision, effort none) | not run | Free `pdf-text` engine: BAC 5/13; scan: empty | BAC 13/13 (plus a zero "balance brought forward" row) and scan 21/21, both reconcile |

- **Only OpenRouter takes RubyLLM's file part.** RubyLLM sends a PDF as a `file` part to every
  OpenAI-compatible server. llama.cpp and Gemini's compatible API reject it with a 400.
  `convert_unsupported_attachments` never runs for them, because RubyLLM thinks the protocol
  supports PDFs. Sure has to decide what to send from the model's capabilities.
- **Page images are what works for a vision model.** Gemini and Super VL read the scan
  completely. They didn't count the twice-listed transactions twice, and they took page 1's
  version of the disputed row, the one the running balances agree with. Today's image
  fallback is the right shape, but its five-page limit stays a limit.
- **The text layer works for a capable model**, even with OCR errors: llama.cpp's Qwen3.6 and
  Gemini both got 13/13. On the scan's empty text layer both returned an empty statement rather
  than making one up.
- **Wrong answers look right, and reconciling catches them.** Lightning booked "Balance brought
  forward" as a −£40,000 transaction, merged two rows into −£118.34 and flipped a sign, while
  reporting both balances correctly. Every wrong extraction in the matrix fails to reconcile,
  and every right one reconciles. Sure can run that check on any import without knowing the
  answer, and hold back or flag one that fails. It checks amounts and signs, not dates: in the
  OCR runs below, an extraction with every amount right and ten dates wrong still reconciled.
  See "Checks on an extraction" for the checks measured on every recording.
- **OpenRouter bills PDF parsing, even for free models.** With no engine named, OpenRouter
  OCR'd the scan for the text-only Lightning, and the model saw every amount. The cost was
  $0.002 a page, once for every request. The `auto` chain sent each file three times, so the
  spike's first run spent $0.018 (cassettes `openrouter_default_engine_*`, kept and never
  re-recorded). Naming the free `pdf-text` engine
  (`plugins: [{id: "file-parser", pdf: {engine: "pdf-text"}}]`) costs nothing, but reads only a
  text layer, and less well than Sure's own: 1,216 input tokens against 825, and 2/13 against
  9/13 on Lightning. OpenRouter returns the parsed file as an annotation, to be sent back so it
  isn't parsed again. RubyLLM doesn't send it back.
- **Two error-path fixes:**
  - **A 500 that isn't an outage.** llama.cpp answers images it can't read with a 500, which
    section 9 treats as an outage (failover and a down mark). Checking the route's `vision`
    need before sending avoids it.
  - **The `auto` chain retries a 400 that isn't about the JSON mode.** It resends the whole
    file twice more on a 400 like "unsupported content[].type", on Gemini and llama.cpp.
- **The `auto` chain and empty answers.** A statement that really is empty is "mostly null", so
  `auto` asks twice more. It also rescued Super VL, whose strict-mode answer for the scan was the
  prompt's empty "can't read it" statement, and whose `json_object` answer was complete. Sure
  knows when the text layer is empty, so it shouldn't send an empty text layer at all.
- **Large files stay inline.** RubyLLM uploads a file over Anthropic's 24 MB inline limit, or
  over 50 MB on the `:openai` provider, to the provider's Files API, where it stays until
  deleted. On local servers that means posting to `/v1/files`. Sure's adapter sets
  `auto_upload_large_files = false` (`extract_statement_stubbed_test`).
- **The rest:**
  - the `.ai` event carries each file's name and size, never its bytes;
  - Anthropic gets a base64 `document` block for the PDF and `image` blocks for pages (stubbed);
  - the hand-written transports refuse attachments rather than drop them;
  - these cassettes add 10.5 MB, because the retries resend the base64 file.
- **Not tested:**
  - OpenAI direct (the Responses API's `input_file`) and Anthropic live, whose keys have no credits;
  - a local vision model for direct extraction: see "OCR on llama.cpp" below for local OCR;
  - statements over five pages.

**Conclusion.** RubyLLM carries the bytes well, but the choice of what to send stays Sure's: one
small step before `generate` in place of today's three classes. With a vision model, send page
images. Without one, send the text layer. If the text layer is empty and there's no vision
model, the feature is unavailable ("no model can read scanned PDFs"). Send the PDF itself only
to providers that read it natively (Anthropic, OpenAI) or to OpenRouter with a named engine.
Reconcile every result.

### Rendering pages: pdftoppm today, ruby-vips in the spike

**What Sure does today.** One place renders pages,
`Provider::Openai::PdfProcessor#convert_pdf_to_images`
(`app/models/provider/openai/pdf_processor.rb:229`), with
`system("pdftoppm", "-png", "-r", "150", pdf_path, output_prefix)`. It writes the upload to a temp
directory and reads the PNGs back. `nil` from `system` means `pdftoppm` isn't installed, and
`false` means it failed.

- **When it runs:** only on the OpenAI-compatible path, and only for a scan. `:auto` mode tries
  the text layer first and renders when that fails; `:vision` renders straight away. The
  Anthropic path sends the PDF itself and renders nothing. Callers are `ProcessPdfJob`
  (`ai_low_priority`) and the admin health probe, which renders a synthetic PDF.
- **Every page, for five.** No `-f`/`-l` page range is passed, so `pdftoppm` renders the whole
  upload, and `process_with_vision` sends `first(5)`. A 200-page statement renders 195 pages
  that are thrown away.
- **No limits.** Nothing bounds its time or memory. A PDF that makes poppler hang holds the job
  indefinitely. The health probe's `Timeout.timeout` raises in the Ruby thread but doesn't kill
  the child.
- **The isolation is partial.** The child has its own memory, so a poppler crash doesn't take
  the worker down. But it runs as the same user with the same file access, and it inherits the
  worker's environment, which on most deployments holds API keys and the database URL. It's a
  guard against crashes, not against a poppler exploit.
- **The upload is parsed in process anyway.** `pdf-reader` reads the text layer inside the
  worker, for `Pdf::TextExtractor`, `BankStatementExtractor`, statement metadata detection and
  `VectorStore::Embeddable`. The last runs on a web thread today. `pdf-reader` is pure Ruby: a
  hostile PDF can make it raise or burn CPU, but not corrupt memory the way a bug in C code like
  poppler can.

So the choice for the plan isn't "isolated or not". `ruby-vips` in process adds poppler, C
code, to a worker that already parses the upload with pure-Ruby `pdf-reader`. Today's child
process keeps poppler's memory out of the worker, but shares its environment and has no limits.
A child process that isolates properly, running either `pdftoppm` or `ruby-vips`, needs:
- a timeout that kills it;
- a page range (`-f 1 -l 5`, or vips's `page:` and `n:`);
- a stripped environment (`system({}, "pdftoppm", …, unsetenv_others: true)`);
- ideally, a memory limit.

**The hardened `pdftoppm`, built and tested** (`Pdf::PageImages`, `page_images_test`, with PDFs
built to misbehave and stand-in `pdftoppm` scripts):

- **The child process:**
  - `Process.spawn({}, …, unsetenv_others: true)`, so the child's environment is empty: a
    stand-in that writes its `env` saw none of the worker's variables;
  - `pgroup: true` and a 30 s timeout that kills the whole group: a stand-in that hangs, with a
    `sleep` child of its own, was killed after 1 s with both processes gone;
  - `rlimit_cpu: 60` and `rlimit_as: 1 GB`;
  - `-f 1 -l 5`: a 300-page upload renders five pages, in about a second with either renderer.
- **`pdftoppm`'s exit status can't be trusted.** A page it can't allocate isn't an error. Two
  cases:
  - poppler's own guard: a 200-inch page, 900 million pixels at 150 dpi, gets "Bogus memory
    allocation size";
  - the memory limit: a 100-inch page, 225 million pixels, under 512 MB, gets "Out of memory".

  Either way `pdftoppm` writes a **1×1 PNG and exits 0**, and Sure's current code would send
  that blank pixel to the model as the page. The hardened path checks every page's size after
  rendering. Without a limit, the 100-inch page renders in about 3 s, at 15,000 × 15,000.
- **A pixel limit before rendering, for both renderers.** Each page's MediaBox, read with
  `pdf-reader` (which already parses every upload), must come to at most 25 million pixels at
  the requested dpi, about 23 inches square at 150 dpi. This is the only memory guard
  `ruby-vips` has, because it renders inside the worker, beyond any process limit. A file
  `pdf-reader` can't open is refused before either renderer runs.
- **Not covered:**
  - the child still runs as the worker's user, with its file access. Confining it needs a
    sandbox such as bubblewrap, or a separate container;
  - a PDF crafted to be slow rather than large, which only the timeout and CPU limit stop.

### Checks on an extraction

`ExtractBankStatement#checks` runs on any extraction, without the answer, and
`ExtractBankStatement.for_pdf` chooses the input:
- page images with a vision model;
- the text layer otherwise;
- `Ai::Error::Unavailable` (`no_text_layer`) for a scan with no vision model, so an empty text
  layer is never sent.

Every recorded extraction, from the PDF matrix and the OCR runs, carries its checks in its pinned
summary:

| Check | What it is | Kept |
|---|---|---|
| `reconciles` | The opening balance plus every transaction equals the closing balance (zero rows ignored) | Yes |
| `amounts_in_source` | Every amount appears in the text the model read, the text layer or the OCR transcription; `nil` for images | Yes |
| `dates_anchored` | The share of rows whose date is the last date printed in the 120 characters before that row's amount | Yes, at 0.5 or more |
| Dates in the source anywhere | Every date appears somewhere in the source | No: WeVisOne's wrong dates ("1 February", "14 Feb") appear, in "Balance at 1 February" and "timed 9.52 14 Feb" |
| Dates in the period | Every date falls in the reported period | No: models write the period to fit their dates, so it caught nothing, and it failed a right extraction (Gemini, scan images) |

**Result:** the three kept checks pass all 14 right extractions and fail all 12 wrong or empty
ones, with no false alarms. Rows where the model returned an error count as neither.
- **`reconciles` catches all but one,** the amount, sign, missing and merged-row errors.
- **`dates_anchored` catches the one left,** WeVisOne → Qwen: every amount right, ten dates wrong.
  It scored 0.08 and 0.15 there, against 0.62–0.77 for right extractions. Right ones fall short
  of 1.0 for two reasons: one printed date can head two rows, and the scan lists each row twice.
  The threshold is tuned on two statements, so it's a heuristic, not a rule.
- **For images read directly there's no source text,** so only `reconciles` applies.

**Ruby gems.** No Ruby gem renders a PDF on its own: each
one wraps poppler, MuPDF or Ghostscript. `ruby-vips` is already in the bundle (2.2.4, through
`image_processing` for Active Storage), and the Dockerfile already installs `libvips`. Debian's
`libvips` renders PDFs with poppler (`libvips42t64` depends on `libpoppler-glib8t64`), the
engine behind `pdftoppm`. The spike's `Pdf::PageImages` (21 code lines) renders every page in
process:

- **Same output.** Sure's base image (`ruby:3.4.9-slim`, Debian 13, libvips 8.16.1) and the
  test host (libvips 8.18.5) give the same page sizes as `pdftoppm` at 150 dpi, give or take a
  pixel: 1275×1650 for US Letter. Gemini read the `vips` renders exactly as it read
  `pdftoppm`'s, with the same results and input tokens.
- **What it gains:** no subprocess, temp files or `system` return codes; errors are
  `Vips::Error`; and the page count, so the five-page limit is a choice. `poppler-utils` could
  leave the Dockerfile, though the poppler library stays as `libvips`'s dependency.
- **What it costs: Rails blocks it, deliberately.** Active Storage calls
  `Vips.block_untrusted(true)` at boot (`active_storage/vips.rb`), which blocks every libvips
  operation not fuzzed for untrusted input. The PDF loader is one of them, so in Rails
  `pdfload_buffer` raises "operation is blocked". `Pdf::PageImages` unblocks only
  `VipsForeignLoadPdf`, behind a mutex, while it renders, and blocks it again
  (`page_images_test`). That has two costs:
  - the block is process-wide, so while a render runs any libvips call in the process,
    an Active Storage variant included, can decode a PDF;
  - poppler parses the user's upload inside the Rails worker, where `pdftoppm` parsed it in a
    child process. A poppler crash or exploit would then hit the worker.
- **For the plan:** three choices.
  - A child process with the limits above keeps poppler away from the worker's memory and
    secrets. That's today's `pdftoppm`, hardened.
  - `ruby-vips` in process is simpler, but needs the unblock above.
  - `ruby-vips` in a child process keeps both properties, for more code.

  The spike uses the in-process unblock to show that it works; the choice belongs to the plan.

`Pdf::PageImages` takes `renderer: :vips` (the default) or `renderer: :pdftoppm`. The `pdftoppm`
path is Sure's call today, plus `-l` for a page limit. At 150 dpi `pdftoppm` gives BAC's page as
933×1219 and `vips` as 932×1218; the Letter pages match exactly.

### OCR on llama.cpp: Unlimited-OCR-2 and WeVisOne-VL-4B

`ocr_live_test`, cassettes under `ocr/`. Three vision models ran, each loaded in turn on the test host's
llama.cpp (CPU only), on both statements, with pages from both renderers at 150 dpi. Requests ran
one at a time. Each run had two steps, recorded apart, because the server holds one model at a
time:
1. **Transcribe:** the vision model turns the page images into text. Chat messages now carry
   attachments for this, and the `.ai` event records only each file's name and size.
2. **Extract:** Qwen3.6 extracts the statement from that text with `ExtractBankStatement`,
   scored like the matrix above.

The three models:
- **Unlimited-OCR-2** (baidu, 3.3B MoE) in two GGUF conversions:
  - AtomicChat's (`Unlimited-OCR-2-AD-Q4_K`);
  - RX5950XT's (`Q4_K_M`).

  The model card's prompt is `<PAGE><image>` per page, then "Multi page parsing.".
  AtomicChat's chat template writes it around images sent alone. RX5950XT's only joins the
  messages, so the request sends one user message per page (`"<PAGE>"` and its image) and a
  last one with the instruction. RubyLLM puts a message's text before its files, so this is the
  only way to get that order.
- **WeVisOne-VL-4B** (`Q4_K_M`), a general vision model, asked to transcribe to Markdown.

| Model · renderer | BAC: amounts read · extraction | Impact scan: amounts read · extraction | Time per page |
|---|---|---|---|
| OCR-2 AtomicChat · `pdftoppm` | 13/13 · 13/13, reconciles | 21/21 · 21/21, reconciles | 43–47 s |
| OCR-2 AtomicChat · `vips` | 13/13 · 13/13, reconciles | 21/21 · 21/21, reconciles | 47–48 s |
| OCR-2 RX5950XT · `pdftoppm` | 13/13 · 13/13, reconciles | 21/21 · 21/21, reconciles | 44–48 s |
| OCR-2 RX5950XT · `vips` | 13/13 · 13/13, reconciles | 21/21 · 21/21, reconciles | 45–48 s |
| WeVisOne · `pdftoppm` | 13/13 · 3/13, reconciles | not run | 115 s |
| WeVisOne · `vips` | 11/13 · 3/13, doesn't reconcile | not run | 113 s |

Qwen3.6's extraction took 73–123 s more per statement. Two BAC extractions added a zero
"Balance brought forward" row, which does no harm.

- **Unlimited-OCR-2 then Qwen3.6 read both statements completely,** the scan included, on CPU,
  with either conversion and either renderer. It fixed the BAC text layer's OCR errors. It kept
  the printed figures (`£44.079.83`), and the extraction step read them correctly. The two
  conversions gave almost the same text, and so did the two renderers. It's the first
  local path in the spike that reads a scanned statement.
- **Table cells come out joined.** The OCR model writes tables as HTML. Every `<tr>`, `<td>` and
  `</td>` is missing from llama-server's output; only `<td rowspan="2">`, which the tokenizer
  spells out, survives. So `24.50` and `39,975.50` arrive as `24.5039,975.50`. The tags are
  special tokens, which llama-server leaves out of text by default. **With `--special`**
  (RX5950XT's build, `rx5950xt_special`), the same output (1,009 and 2,064 tokens, either way)
  arrives as proper HTML: 18 rows and 84 cells on BAC, empty cells included, so "Money out" and
  "Money in" stay apart. The end-of-sequence token `<｜end▁of▁sentence｜>` arrives too, and Sure
  has to strip it. Qwen3.6 split the joined values correctly every time without it, but a
  weaker model might not.
- **WeVisOne isn't a transcriber or an extractor.**
  - **Transcribing:** it ignored the Markdown instruction and answered with grounding pairs
    (`<ref>24.50</ref><box>…</box>`). It quietly corrected printed errors (`£44,079.83`) and
    left out all but one of BAC's date cells. Qwen then dated ten rows from their
    descriptions: every amount and sign right, ten dates wrong, and one of the two runs still
    reconciles.
  - **Extracting straight to JSON** (`EXPECTED_DIRECT`, three runs):
    - grounding tags in the descriptions;
    - invented years;
    - loops until the 6,000-token cap at 7.9 tokens a second, so BAC took 26 minutes over the
      `auto` chain's three attempts;
    - on the scan, both balances right and no transactions.
- **For the plan:**
  - **Local OCR works for PDF import:** an OCR model to transcribe, then the extraction
    generation on any text model. That needs two models on a route (`needs: vision` for the
    transcribe step), or a dedicated OCR endpoint, since one llama.cpp server holds one model
    at a time.
  - **A prompt per model:** the request has to match each model's prompt and chat template,
    so the OCR step needs one per model, not a generic instruction.
  - **Time budgets:** `auto`'s retries multiply a slow local model's time, so a route needs
    a budget for each attempt as well as for the turn.
  - **Dates:** reconciling doesn't check them. A period check wouldn't have caught WeVisOne's
    (the wrong dates fall inside the period); `dates_anchored` does (see "Checks on an
    extraction").
- **Not run:**
  - WeVisOne's two scan transcriptions, because the server stopped mid-run for a model change;
  - its `vips` BAC direct extraction, which would likely take another 26 minutes;
  - 300 dpi, the model card's recommendation;
  - Qwen3.6's extraction from the `--special` transcriptions, and `--special` on the other
    builds.

## Tracing modes: content and metadata, outside the criteria

Tracing has two modes, and an operator picks one with `Ai::Instrumentation.start_tracing`:

| Mode | Source | What leaves the server | For |
|---|---|---|---|
| `content` (default) | Sure's `.ai` events through `Ai::Instrumentation::LangfuseSubscriber` | Prompts, outputs, usage, route, Sure's error class, session | Debugging prompts and evals in Langfuse |
| `metadata` | RubyLLM's own OpenTelemetry spans through `Ai::Instrumentation::MetadataTracing` | Model, settings, finish reason, tokens (with cached), latency, RubyLLM's error class, session. No prompts, tool results, answers or error bodies | Operators who want cost and latency without sending financial data to a tracing backend |
| `off` | — | Nothing | — |

The two never run together, or Langfuse would get each generation twice, once without content.
Usage rows and the debug log are local subscribers and run in every mode.

**Why `metadata` is RubyLLM's job.** RubyLLM 2.1.1 has no Langfuse integration, but
`RubyLLM::OpenTelemetry.enable` turns its events into spans on the global OpenTelemetry tracer,
using the GenAI semantic conventions. `lib/ruby_llm/open_telemetry/attributes.rb` sets only the
operation, provider, model, temperature, max tokens, stream flag, finish reason and token counts.
Nothing in the gem sets `gen_ai.input.messages`, `gen_ai.output.messages` or Langfuse's
`langfuse.observation.input` and `output`, and a failure records only `error.type`, the class name.
So the privacy comes from the gem not having the code to send content, not from a setting that
someone could flip on.

**Sure's part is small** (`app/models/ai/instrumentation/metadata_tracing.rb`, 19 lines, plus 12 for the mode switch in `app/models/ai/instrumentation.rb`):

- an OpenTelemetry tracer provider exporting OTLP, set up by the standard
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_EXPORTER_OTLP_TRACES_HEADERS`, so the backend can
  be Langfuse, Tempo, Jaeger or OpenObserve;
- a span processor that stamps the job's correlation id as `session.id` on every span. RubyLLM
  can't set a session, and Langfuse v4 doesn't copy a parent span's session to its children, so
  without it the spans don't group by job. `RubyLLM.workflow` only adds a parent span.

**Evidence.**

- `test/models/ai/metadata_tracing_test.rb` replays the llama.cpp `generate_ruby_llm` and
  `converse_tool_round` cassettes into an in-memory exporter. It expects three `chat` spans with
  the model, usage and session, and checks that no span name, attribute, event or status contains
  the charges, categories, instructions, question, tool result or answer. A 500 whose body echoes
  a charge leaves only `error.type = RubyLLM::ServerError`.
- `test/models/ai/live/langfuse_otel_check.rb` runs the `metadata` mode live against a self-hosted
  Langfuse. Langfuse groups the three generations under the job's session, with model, usage
  (including cached tokens) and latency, and empty input and output.

**What `metadata` loses:** the route and prompt key, Sure's `Ai::Error` class (it gets RubyLLM's),
and errors raised before RubyLLM is called (`Unavailable`, `Busy`). The global tracer provider is
also shared with any other OpenTelemetry instrumentation Sure adds later, which could carry
content of its own.

## Job runners and chat priority (rubyllm.com/async), outside the criteria

RubyLLM's async guide runs AI jobs on fibers: Solid Queue 1.6+ workers with `fibers: N`, or
Async::Job on Redis, with `isolation_level = :fiber`. The plan runs them on Sidekiq's `ai`
capsule, `RAILS_AI_MAX_THREADS` threads (default 1), three lane queues in strict order and one
slot per local host (§11). Solid Queue 1.7.0, `async` 2.46.0, `async-job-adapter-active_job`
0.21.0 and `async-job-processor-redis` 0.3.1 are on the spike branch only, loaded with
`SPIKE_ASYNC=1`; workers run inside the test process, Solid Queue's tables live in the test
database for one test, and every scenario ran alone. `RAILS_MAX_THREADS` stayed at 3, the
database pool.

**Many cloud calls at once** (`job_backends_live_test`): 200 jobs, each one bill setup against a
stub provider (`stub_provider.rb`) that answers after 2 s, plus a database read before and after.

| Runner | Wall | In flight | Threads | Memory | Pool waiting (peak) |
|---|---|---|---|---|---|
| Sidekiq, 5 threads | 80.6 s | 5 | 15 | 348 MB | 0 |
| Sidekiq, 50 threads | 8.6 s | 50 | 60 | 340 MB | 38 |
| Sidekiq, 200 threads | 3.1 s | 200 | 210 | 362 MB | 159 |
| Solid Queue, 50 threads | 9.8 s | 50 | 59 | 372 MB | 42 |
| Solid Queue, 50 fibers | 9.5 s | 50 | 10 | 349 MB | 39 |
| Solid Queue, 200 fibers | 3.0 s | 200 | 10 | 351 MB | 158 |
| Async::Job on Redis | 2.4 s | 200 | 7 | 367 MB | 0 |

- **Concurrency sets the wall time, not the runner.** Sidekiq at 200 threads matched 200 fibers.
  Memory stayed within 32 MB across all of them, and none needed more than the 3 connections:
  Rails 8.1 returns the connection after each query, so callers queue for it briefly instead.
- **Above a provider's limit** (the stub allowing 20 at once, 429 with `Retry-After: 1`
  above it, `max_retries: 3`): Sidekiq at 50 threads lost 80 of 200 calls, Solid Queue at 200
  fibers and Async::Job 160 each. More concurrency than the provider allows turns into failures;
  a per-endpoint limit would be the fix, and neither runner nor RubyLLM has one.

**Sure's code inside a fiber reactor** (`fiber_compat_live_test`, 20 calls at once against the stub
answering in 1 s):

| What | Result |
|---|---|
| RubyLLM `generate`, default `net_http` adapter | 1.14 s: the calls overlapped |
| RubyLLM, `async_http` adapter (`async-http-faraday`) | 1.02 s |
| Hand-written transport (ruby-openai on Faraday) | 1.02 s |
| Streamed chat, 20 conversations | First chunk at 0.26 s for all 20 |
| Jev's 8-thread pool, 10 batches of 8 at once | 1.15 s, 80 requests in flight |
| `Current` across two fibers | Fiber isolation: each kept its own; thread isolation: both read the second's |
| 50 fibers querying around a 0.5 s wait, pool of 3 | 0.53 s, no errors |
| 9 fibers holding a transaction for 2 s, pool of 3 | 6.06 s: three at a time, inside the 5 s checkout timeout |
| Rendering both statements' pages | `vips` stalled the reactor 0.28 s of 0.33 s; `pdftoppm` 0 |

Sure's whole suite with `SPIKE_ISOLATION=fiber` (fiber isolation app-wide): 13,944 runs, one
failure, `page_images_test`'s hang-kill timing check, which passed alone under both isolation
levels.

**One machine, chat first** (`gpu_priority_live_test`): llama.cpp on the test host, qwen3.6 with
reasoning off. Twelve bill setups (about 9 s each) are queued, then, 3 s later, one streamed
chat; times are from the chat's enqueue.

| Setup | llama `--parallel` | Chat's first word | Background done |
|---|---|---|---|
| Sidekiq, 1 thread, strict queue order (the plan's default) | 1 (MTP on) | 6.0 s | 107 s |
| Solid Queue, 50 fibers, no priority | 1 (MTP on) | 102.2 s | 105 s |
| Solid Queue, 1 fiber, chat at a higher priority | 1 (MTP on) | 6.1 s | 108 s |
| Solid Queue, 50 fibers, the plan's slot (`Ai::Spike::LaneSlot`) | 1 (MTP on) | 5.6 s | 109 s |
| Solid Queue, 50 fibers, no priority | 4 (MTP off) | 91.2 s | 97 s |
| The slot, 4 calls at a time | 4 (MTP off) | 19.2 s | 75 s |
| The slot, 4 calls, 1 kept for chat | 4 (MTP off) | 0.6 s | 102 s |

- **Fibers alone put chat last.** Every call reaches the server at once and llama-server answers
  in arrival order, with 1 slot or 4.
- **The plan's slot works on fibers unchanged:** its `Monitor` and lane-ordered waiters, under
  the fiber scheduler, gave the same result as Sidekiq's single thread, while the 50 claimed
  jobs waited as fibers instead of being re-enqueued.
- **Parallel server slots are a trade, not a limit.** Four slots finished the background 30%
  sooner even with MTP off, at the cost of each call taking 22-26 s instead of 9 s. Keeping one
  slot for chat gave the fastest first word measured (0.6 s) and gave back most of the
  throughput gain. MTP and `--parallel` were changed together, so their effects aren't
  separated.

**Chat and embeddings on one machine** (`gpu_contention_live_test`): the chat server and the
embedding server run in two containers on the same host (ports 8180 and 8181), unaware of each
other. Sixty embedding jobs (64 texts each, the prompt lane) are queued, then a chat; llama at
`--parallel 4`, MTP off.

| Setup | Chat's first word | Chat done | Embeddings done |
|---|---|---|---|
| Chat alone | 0.36 s | 2.22 s | |
| Embeddings alone | | | 18.0 s |
| Both, uncoordinated | 0.27 s | 2.53 s | 19.3 s |
| Both, one host slot held inside RubyLLM | 0.39 s | 2.28 s | 20.8 s |

- **The slot can live inside RubyLLM.** Each RubyLLM context takes an `instrumenter`, a public
  setting, and RubyLLM runs every HTTP request it makes, streamed or not and with its retries,
  inside `instrument("request.ruby_llm")`. `Ai::Transport::SlotInstrumenter` holds the
  endpoint host's slot for that block, in the lane the job sets
  (`SlotInstrumenter.with_lane`), and forwards every event to the instrumenter it replaced. In
  the run the slot granted 61 requests, one at a time; chat waited at most 0.17 s, the end of one
  embedding request, and embeddings up to 17.8 s.
- **On the test host the embeddings barely slowed chat** (2.53 s against 2.22 s alone), with or without
  the slot. The embedding model is small, and the host already ranks chat above embeddings with
  `Nice=` on the shared cores. A larger embedding model, or no `Nice=` ladder, could change that;
  not tested.
- **What the instrumenter's slot doesn't do:** it holds a slot per HTTP request, so a chat's
  tool rounds can be interleaved with other requests; it lives in one process, like the plan's;
  and it can't see Jev's or the hand-written transports' requests, which don't go through
  RubyLLM.

**Merchant detection and chat on the same model** (`gpu_merchants_live_test`): both go to
qwen3.6 on llama.cpp, `--parallel 4`, MTP off. Eight `detect_merchants` jobs (the prompt lane, 25
transactions each, today's custom-provider instructions as `Ai::Generations::DetectMerchants`)
are queued, then, 20 s later, one chat turn with 3.3k tokens of transactions as context, as after
a tool round. Solid Queue, 50 fibers, so every job is picked up at once. The slot sits in
RubyLLM's instrumenter, sized from llama-server's `/props` `total_slots`, so Sure drains its
queue into the server's slots and llama-server's own queue stays empty. One run each.

| Setup | Chat's first word | Chat done | Chat's output | Merchants done |
|---|---|---|---|---|
| Chat alone | 44.4 s | 65.5 s | 11.6 tok/s | |
| Merchants alone | | | | 410 s |
| Every call sent at once (llama-server queues the rest) | 369.4 s | 396.1 s | 11.2 tok/s | 391 s |
| Drain: at most 4 calls at the server, chat first in Sure's queue | 197.8 s | 237.2 s | 5.5 tok/s | 412 s |
| Drain, 1 of the 4 kept for chat | 48.2 s | 103.2 s | 5.5 tok/s | 489 s |
| Drain, 1 kept, no merchant call starts while chat runs | 48.6 s | 103.4 s | 5.5 tok/s | 489 s |
| Drain, none kept, no merchant call starts once chat waits | 234.0 s | 276.5 s | 5.7 tok/s | 632 s |

- **llama-server's queue is where chat gets lost.** Sent at once, the chat queued behind four
  merchant calls inside the server, where nothing in Sure can reorder it: 369 s to the first word.
- **Draining halves that, and no more.** Holding the calls in Sure, chat first, the chat still
  waited 149 s for a running merchant call to end (each takes 115-215 s at four at a time).
  With calls this long, priority in a queue can't help; the chat needs a free slot.
- **A slot kept for chat is what makes it interactive:** 48 s to the first word, against 44 s
  alone (the time to read 3.3k tokens of context on this CPU). The chat's output runs at half
  speed (5.5 tok/s against 11.6) while it shares the CPU with three merchant calls, so it
  finished at 103 s instead of 66 s. Merchants took 19% longer, with only three slots.
- **Pausing other calls didn't help.** Every merchant call outlasted the chat, so none was due
  to start while it ran; with none kept, pausing only left slots empty (merchants 632 s). A
  pause that stops running calls isn't possible from Sure: llama-server has no request priority
  or preemption, so the only way is to cancel a call and send it again later.
- **The merchant answers didn't change:** 200 of 200 answered and 167-169 named in every run.

**Sidekiq against Solid Queue, and two workers** (same test, same load, one run each). Every
setup keeps one of llama.cpp's four slots for chat; "peak" is the most requests at llama.cpp at
once.

| Setup | Chat sent after | Chat's first word | Merchants done | Peak at llama.cpp |
|---|---|---|---|---|
| Solid Queue, 1 worker, 50 fibers, slot in RubyLLM (above) | 0.1 s | 48.2 s | 489 s | 4 |
| Sidekiq, one capsule of 4 threads, strict queue order, same slot | 136.1 s | 184.1 s | 494 s | 4 |
| Sidekiq, 3 threads for the prompt lane and a 1-thread chat capsule, same slot | 0.0 s | 48.3 s | 543 s | 4 |
| Solid Queue, 2 workers, each with its own in-process slot | 0.1 s | 200.1 s | 416 s | 7 (6 merchant) |
| Solid Queue, 2 workers, `limits_concurrency` (merchants to 3, chat to 1), no slot | 0.2 s | 48.2 s | 547 s | 4 |

- **On threads, the kept slot needs a kept thread.** With one capsule all four threads took
  merchant jobs, three at llama.cpp and one waiting at the slot, so the chat job sat in Sidekiq's
  queue for 136 s until a thread came free. Strict queue order only decides what a free thread
  takes next. A one-thread chat capsule (Sidekiq's per-capsule thread pools) matched the fiber
  worker exactly. Fibers don't have the problem while there are more fibers than queued jobs.
- **In-process slots don't add up across workers.** Two workers, each keeping one of four places
  for chat, let six merchant calls through to a four-slot server; the chat was sent at once and
  queued inside llama-server behind them. The plan's slot (§11) has the same limit with two
  Sidekiq processes, whatever the capsules.
- **Solid Queue's `limits_concurrency` holds across workers.** Its semaphore is a database row,
  so two workers never had more than three merchant jobs running, and chat's own key kept its
  place: 48.2 s, the same as one worker. The two workers ran in one process; the semaphore is the
  same row from separate processes, but that wasn't run. Blocked jobs are released in priority,
  then arrival, order (`BlockedExecution.ordered`). The limits:
  - it counts jobs, not requests: a job holds its place for its whole run, including work
    before and after the call;
  - the key is computed from the job's arguments at enqueue, but the router picks the route,
    and fails over, when the job runs, so a job that fails over to a cloud route still holds the
    local host's place, and the key can't follow a route change without re-enqueueing;
  - the semaphore expires after `duration` (3 minutes by default) so that a dead worker can't
    hold it forever; merchant calls took up to 216 s here, so the default would have let a
    fourth merchant job in;
  - the size is fixed in code at class load, not read from the server's `/props`.
- **Sidekiq has no cross-process equivalent without a paid tier** (Sidekiq Enterprise's
  concurrent rate limiter). A Redis semaphore in Sure would be new code; not tested.

**One slot with MTP: keeping chat first without a kept slot.** A slot kept for chat needs
`--parallel` of 2 or more, which on this llama.cpp build turns MTP off (and splits the context
unless `--kv-unified` is set; the build has it, off by default when `--parallel` is explicit).
The server back at `--parallel 1`, MTP on, 64k context. One run each.

Merchant calls alone, 50 transactions at each batch size (`call_length`):

| Transactions per call | One call | Transactions per minute | Named |
|---|---|---|---|
| 25 | 72 s | 20.8 | 41/50 |
| 10 | 29 s | 20.6 | 41/50 |
| 5 | 15 s | 19.6 | 40/50 |

Chat arriving 20 s after the merchant jobs (100 transactions), Solid Queue fibers, slot of 1 in
RubyLLM:

| Setup | Chat sent after | Chat's first word | Chat done | Chat's output | Merchants done |
|---|---|---|---|---|---|
| Chat alone | 0.1 s | 48.7 s | 69.7 s | 14.2 tok/s | |
| A. Chat next, 25 per call | 45.1 s (20 s into a 65 s call) | 94.4 s | 111.9 s | 13.5 tok/s | 352 s |
| B. Chat next, 5 per call | 8.3 s (7 s into a 15 s call) | 57.7 s | 70.5 s | 13.7 tok/s | 373 s |
| C. Chat interrupts the call, 25 per call | 0.1 s | 50.6 s | 71.7 s | 14.2 tok/s | 353 s |
| C on Sidekiq: 3 prompt threads, a 1-thread chat capsule, merchant calls streamed | 0.1 s | 48.3 s | 69.2 s | 14.3 tok/s | 382 s |

- **On one slot, batch size is nearly free.** Throughput moved 6% between 25 and 5 transactions
  per call, while the longest call, and so chat's longest wait, fell from 72 s to 15 s. The
  instructions are a cached prefix, so more calls cost little prompt work.
- **Interrupting works, and llama-server drops the abandoned request.** The slot raised
  `Preempted` in the merchant call's fiber (`Fiber.scheduler.raise`); Net::HTTP closed the
  socket, and the chat's first word came 1.9 s after its time alone. Had the server kept
  generating, the chat would have queued behind the remaining 45 s. The merchant call waited
  behind the chat and was sent again; the 20 s of discarded work didn't show in the merchants'
  total (353 s against 352 s) within one run's noise. The chat kept MTP's speed and the full
  context.
- **Against the kept slot at `--parallel 4`** (above): C's chat started as fast (50.6 s against
  48.2 s), finished sooner (71.7 s against 103.2 s, since it had the CPU to itself), and needed no
  context split; merchant throughput was 17 transactions per minute against 24.5 there, because
  four slots without MTP outrun one with it on this CPU.
- **Interrupting works on Sidekiq threads too, through streaming.** `Thread#raise` isn't safe,
  so a call made inside `LaneSlot.with_interrupt` is streamed, and the slot sets that call's flag;
  the transport's chunk block raises `Preempted` at the next chunk, which abandons the request
  (`Compatible#interruptible_generate`, public RubyLLM API only). The chat waited 0.09 s for the
  slot and its first word came at its time alone (48.3 s against 48.7 s). The merchants' total
  was 382 s against 353 s on fibers, one run each; streaming's cost isn't separated from noise.
  RubyLLM's own `Chat#cancel` is the same kind of flag (checked before and after every chunk,
  `raise_if_cancelled!`), but the slot would need each call's chat object.
- **Limits of interrupting:** a flag is only seen when a chunk arrives, so a call still reading a
  long prompt (a PDF's page images) stops when its output starts, not before. Work an interrupted
  call already did is lost: up to one whole call when it's interrupted near its end. Embeddings
  aren't streamed and can't be interrupted this way; they're short (the contention test's
  longest wait behind one was 0.17 s).

**For the plan** (§11 is rewritten on this): fiber workers don't replace the lanes. They replace
the AI thread count, and for cloud work Sidekiq threads did as well at this scale, so AI jobs stay
on Sidekiq with a one-thread chat capsule. What decides chat's wait on one machine is the per-host
gate and what it does when the host is taken. Against the target @josh-sanders set (about 2 s, never more
than 5 s), only interrupting the running call meets it while keeping MTP and the full context:
the gate sits in RubyLLM's instrumenter, sized from the server, and background and prompt calls
on a local host stream so it can stop them. Lane order alone leaves chat behind one whole call; a
kept slot gives up MTP and slows chat's finish. Several workers on one local host need the AI
capsules on one of them, or a limit they share.

## Prompt cache and prompt reads on one slot, outside the criteria

`test/models/ai/live/cache_prefill_check.rb`, llama.cpp on the test host (build `b1-d812350`,
`--parallel 1`, MTP, no cache flags set), one request at a time, the server otherwise idle. Every
prompt carries a nonce. #4237 measured 4–15 minute re-reads when background calls ran between a
chat's rounds on one slot; #4444 held background work while someone typed.

**A. A chat's cache survives other calls between its rounds.** Round 1 is a chat of about 2,640
prompt tokens; round 2 is round 1 plus its answer and a follow-up.

| Between the rounds | Round 2 read again (`prompt_n`) | Round 2 from cache (`cache_n`) | Round 2's first word |
|---|---|---|---|
| Nothing | 40 tokens | 2,640 | 0.9 s |
| A 25-transaction merchant call (567 prompt tokens, 200 out) | 40 | 2,640 | 0.9 s |
| A statement's text (11,575 prompt tokens, 195 s to read) | 40 | 2,639 | 1.0 s |

Round 1 took 37–39 s to its first word each time. This build keeps a slot's evicted prompt and
restores it, so on one slot a background call between rounds didn't cost the chat its cache.
Other servers (Ollama, LM Studio) and older llama.cpp builds weren't tested.

**B. A chat sent while a long prompt is being read.** The statement prompt starts; a chat (about
2,640 tokens, 39 s to read alone) is sent 10 s later.

| Background call | Chat's first word after sending | Of which waiting behind the background call |
|---|---|---|
| Left running (llama.cpp queues the chat) | 247.7 s | about 209 s: the rest of the 195 s read plus 300 tokens of output |
| Its connection closed when the chat was sent | 59.5 s | about 20 s |

- **Closing the connection stops a prompt read**, which an interrupt raised from the chunk block
  can't do, since no chunk arrives until the read ends. It took about 20 s, not at once: the read
  stops between prompt batches (llama.cpp's default `--batch-size` is 2,048 tokens, about 35 s on
  this CPU), so a closed read can still run up to one batch.
- **A merchant call reads its prompt in about 8.5 s** (567 tokens), so a chat sent during it
  waits at most that long with the connection closed.
- **Not tested:** a smaller `--batch-size` or `--ubatch-size`, which should shorten the stop, and
  closing the connection through RubyLLM and Faraday from the gate's thread (the check closed
  `Net::HTTP` directly).

## RubyLLM agents behind the gate, outside the criteria

`agent_gate_live_test`, llama.cpp on the test host (`--parallel 1`, MTP), one run each. The agents are
`RubyLLM::Agent` subclasses built on Sure's RubyLLM context for the endpoint (the agent's
`context`), so their requests pass the instrumenter and the host's gate (`LaneSlot`, one place,
interrupting on). Sure drives each one with `Agent#step` in a bounded loop instead of `ask`.

- **A chat interrupts a background agent, and the agent carries on.** A merchant agent with a
  `lookup_merchant` tool and six transactions: one round of six tool calls, then its answer. A
  chat arrived while it was writing the answer; the gate interrupted it (the chunk block raised
  `Preempted`), the chat waited 0.1 s for the gate, and Sure's loop called `step` again. The tools
  ran six times in all, not twelve: `generate` adds the reply to the history only once it's
  complete, so the interrupted round left the tool results in place and the resent round started
  from them. The answer named all six merchants. Agent 39.8 s in all; the interrupted request had
  run 2.2 s, the resent one 13.2 s.
- **With RubyLLM's Rails persistence (`chat_model`), the same.** At the interrupt the tables held a
  blank assistant row, the placeholder RubyLLM creates when a reply starts. The resent round
  replaced it (`persist_new_message` destroys a blank placeholder), leaving no blank row. Had the
  worker died between the two, the blank row would have stayed until the next step. `Preempted`
  isn't one of the errors RubyLLM's persistence cleans up after (`COMPLETION_ERRORS`);
  `RubyLLM::CancelledError`, which `Agent#cancel` raises, is. `Agent.create!` returns the chat
  record; `Agent.new(chat: record)` wraps it.
- **Tools in parallel threads lose the job's lane.** An interactive agent with two tools that each
  embed a text, `tool_options concurrency: :threads`: both embedding requests ran in the
  background lane, because RubyLLM starts each tool thread with fresh execution state (it runs
  them under the Rails executor, `ToolConcurrency#isolated`). Behind a gate that makes background
  calls re-enqueue (§11, rule 3), a chat's tool would fail or wait. Prepending a module that keeps
  the lane captured when the tool is built (`CarriesLane`, 4 lines) ran both in the interactive
  lane. RubyLLM's own way to carry context into tool threads, `Support::Instrumentation`
  subscribers with `capture_context`, is `:nodoc:`.
- **That's RubyLLM's design, not a bug in it.** `ToolConcurrency#isolated` says why: a tool
  thread runs as its own unit of work so its database connections return to the pool, and a
  fiber that shared the caller's state would reset the caller's `Current` when it finished. The
  gap was in the spike, which kept the lane in per-thread state; the fix uses public API only.
  No RubyLLM issue asks for a public way to carry an app's own context (a lane, a tenant, a
  trace) into tool workers, and its recent work in that code (#1326, "Propagate cancellation
  checkpoints to child fibers") carries only its own state. Asking for one is optional and not
  filed: Sure doesn't need it.

## RubyLLM's usage ledger, outside the criteria

`ruby_llm_usage_ledger_test`, WebMock with the OpenAI-compatible shapes, no server. Sure records
usage in `llm_usages` today, and the plan writes it from Sure's `.ai` events (§10). RubyLLM 2.1
has a ledger of its own: once `ruby_llm_usages` exists, it writes a row for every provider
attempt, owned by whatever `RubyLLM::Accounting::Usage.with_owner` set, and it publishes a
`usage.ruby_llm` event for every attempt whether or not the table exists. Three ways to record
usage were compared: (A) the ledger as the record, (B) a Sure subscriber writing the
`usage.ruby_llm` events into `llm_usages`, and (C) the plan's `.ai` events.

| What happened | A: ledger rows | B: `usage.ruby_llm` events | C: `.ai` events |
|---|---|---|---|
| One bill setup | 1 row: `chat`, succeeded, 400 in, 100 out, owner the family, cost `nil` | 1 | 1 |
| Two 503s RubyLLM retried, a 400 the `auto` chain answered with `json_object`, then success (4 requests) | 4 rows: failed (tokens unknown), failed (unknown), failed (0 tokens, cost 0), succeeded | 4 | 1, with the last request's tokens |
| A call the gate interrupted, then resent | failed (cost 0), succeeded | 2 | not tested |
| An embedding | `embedding`, 7 tokens | 1 | 1 |
| A call outside `with_owner` | a row with no owner | no owner | — |

- **Sure's own fields have nowhere to go.** The ledger has no feature, route, correlation id or
  metadata column. Its `operation` is checked against RubyLLM's eleven (`chat`, `embedding`,
  `judgment`, …), so `suggest_bill_setup` is refused, and `provider` is RubyLLM's slug: `openai`
  for a llama.cpp endpoint, not the endpoint's name. The usage page, the API and §10's health
  rates read those fields. `RubyLLM::ActiveRecord::Usage` is marked `:nodoc:`, "RubyLLM's
  private normalized persistence".
- **Prices come only from RubyLLM's registry.** A local model's cost is `nil`; Gemini through
  the native provider was priced ($0.00037). Sure's plan prices from each model's own
  `input_cost_per_mtok` and `output_cost_per_mtok`, which covers local and unregistered models.
- **Tokens agree.** With 11,945 of 12,457 prompt tokens cached, the ledger and Sure's `Ai::Usage`
  both said 512 input and 11,945 cache read: both read RubyLLM's counts.
- **An interrupt is a failure, not a cancellation.** `Preempted` isn't `RubyLLM::CancelledError`,
  so the abandoned request is `failed`. A health rate built on failures would count every
  interrupt, unless the gate raised RubyLLM's own cancellation.
- **Attempts are visible only to A and B.** RubyLLM's retries and the `auto` chain's resends
  happen inside one `.ai` event, so the plan's §10 records one row for four requests. Failed
  attempts carried no tokens (503) or zero (400), so the cost was the same; the count and the
  error statuses weren't. The plan's endpoints set `max_retries: 0`, which leaves only the `auto`
  chain's resends.
- **B's subscriber runs in the caller.** It saw Sure's correlation id (`Ai::Correlation`, a
  thread-local), so Sure's own context can fill the fields RubyLLM doesn't have.
- **RubyLLM's usage owner follows its tool threads.** It lives in fiber storage, which threads
  inherit. Two tools run with `concurrency: :threads` saw the family as owner, and a lane kept in
  fiber storage (`Fiber[:spike_lane]`) arrived as `:interactive`, while the same lane in
  `ActiveSupport::IsolatedExecutionState` arrived empty. Keeping the gate's lane in fiber storage
  would carry it into tool threads without `CarriesLane`.
- **What the ledger costs.** With the table, each attempt adds a savepoint, an insert and a
  release (3 statements). Without it, none: the table check goes to the schema cache.
- **Not tested:** the usage page built from the ledger, a data migration from `llm_usages`, and
  Jev, whose transport isn't RubyLLM and would never reach the ledger.

## One turn per chat (RubyLLM 2.2's "One Process at a Time"), outside the criteria

RubyLLM 2.2, unreleased when this was written (rubyllm.com/next), claims a persisted chat before
any model call or tool run, and each tool call before it runs, with a conditional update of
`claim_token` and `claimed_until` on `chats`; a claim lapses after `max_run_time` (ten minutes by
default) and a run whose claim lapsed has its results discarded. It needs RubyLLM's Rails
persistence, which Sure doesn't use, and the spike can't run unreleased RubyLLM. So
`chat_claim_test` asks two questions on 2.1.1, with today's code (`Chat`, `AssistantResponseJob`,
`Assistant::Builtin`, the responder and the real `create_transaction` tool) and a fake provider
that asks for one `create_transaction` (no `external_id`, so not idempotent) and then answers.
Two jobs run at once on two threads, as on two Sidekiq threads or workers.

`Ai::Spike::ChatClaim` (31 lines) is Sure's own version: claim the chat in `Chat#ask_assistant`
with a conditional update; renew it before each tool run and each responder event, raising
`Lost` if another turn took it over; release it at the end. A job that finds the chat claimed
drops its bubble if the message already has an answer coming (a duplicate) and otherwise
re-enqueues itself 5 s later.

| Case | Today | With the claim |
|---|---|---|
| Retry pressed again after the first | Nothing: `retry_last_message!` acts only when the user's message is the chat's last, and the first Retry's bubble now is | — |
| Two Retry requests at the same moment (both pass that check) | Two turns, two answers, `create_transaction` ran twice: two coffees | One turn, one answer, one coffee; the other job dropped its bubble |
| A second message while a turn runs | A second turn at once; both turns sent the model the same history (both messages, no answer) | The second waits: re-enqueued, its bubble pending until then |
| A turn whose claim lapsed mid-call (worker hung), another took over | — | One coffee: the stale turn's renewal before its tool run failed, and it stopped |
| The same, without renewing before the tool run | — | Two coffees: the stale turn wrote, then stopped at its next renewal |
| A chat waiting at the gate longer than the claim (1 s claim, 2 s wait, no interrupt) | — | A second turn took the claim and answered; the waiting turn's model call was wasted, and its renewal before the tool run stopped it |

- **Nothing in the code stops a second turn on one chat.** The form disables Send only when the
  text is empty, `MessagesController#create` saves and enqueues, and neither the job nor
  `Chat#ask_assistant` checks for a running turn. The double Retry needs two requests within the
  same moment; a second message mid-turn needs nothing unusual.
- **Renewing before every tool run is what stops a stale write**, not the claim itself. RubyLLM
  2.2 claims each tool call for the same reason.
- **A replaced turn must stop quietly.** `Assistant::Builtin#respond_to` rescues every error into
  the chat's error, so the first version showed the user an error although the other turn had
  answered; one rescue clause for `Lost` fixes it (the test does it in `Chat#add_error`).
- **Renewals have to come more often than the claim lapses.** In one of five full-suite runs of
  the first version of the gate test, with a 1-second claim on a busy CPU, more than a second
  passed between two of a turn's renewals, a second turn took the chat in the gap, and both wrote
  (two coffees). The test now holds the gate until the other turn is done. A ten-minute claim
  renewed at every tool run and event leaves a wide margin; a single non-streamed call longer
  than the claim wouldn't.
- **The claim has to outlast the gate's wait.** A chat that waits longer than its claim lets a
  second turn in. With §11's interrupt a chat waits about 0.1 s, and the `ai_chat` capsule runs
  one turn at a time, so a ten-minute claim covers it; a claim that renewed while waiting would
  remove the question.
- **What a message sent mid-turn should do is a product decision:** wait for the turn (as here),
  be refused, or interrupt the turn and start again with both messages.
- **Not tested:** the watchdog's interplay with claims (a turn queued behind other AI work has no
  claim yet, so the watchdog is still what resolves it), RubyLLM 2.2's own claims, and Sidekiq
  processes rather than threads.

## Failover on a gateway (decision 12), outside the criteria

Section 5.4 marks a whole server down on a timeout or 5xx and fails over only to a different
server. That fits a local server, one process that fails as a whole. A gateway is one endpoint
and key in front of many models (OpenRouter, Vercel AI Gateway, Bedrock), and its 503 or 429
usually belongs to one upstream model. `Ai::Spike::Failover` (100 lines) is section 5.4's router
loop with three marking rules, run in `failover_test` against a stubbed gateway (two models, one
key) and a stubbed llama.cpp (two models), with routes `gateway/model-a, gateway/model-b,
llama/qwen3-3b` or `llama/qwen3-3b, llama/gpt-oss-20b, gateway/model-a`:

- **`:plan`**, section 5.4 as written: a timeout or 5xx marks the server, a 429 or 401 the key;
  failover only to another server.
- **`:response`**: the server only when no HTTP response came back (`Unreachable`, which includes
  a connect timeout); a 401 the key; a read timeout, 5xx or 429 only that model on that key.
  Failover may stay on the same server.
- **`:location`**: mark the smallest thing the error proves broken. The server when no response
  came back, or on a timeout or 5xx from a local endpoint (§4.2's `location`: one process fails as
  a whole); the key on a 401; otherwise the model. The next route is the next one not down. The
  call by @josh-sanders during development of PR #4440, with no
  move limit.

| Case | `:plan` | `:response` | `:location` |
|---|---|---|---|
| Gateway: 503 for model-a only | Llama answers; the gateway is down for 60 s, so a feature routed only to model-b is unavailable | Model-b answers, and stays usable | As `:response` |
| Gateway: 429 for model-a only (an upstream's limit) | As the 503: the key is marked, model-b unusable | Model-b answers | As `:response` |
| Gateway: 429 for the whole key | Llama answers (1 gateway call) | Model-a, then model-b (2 calls); the one move is spent, so the call fails although llama was listed | As `:response`; with two moves llama answers after 2 gateway calls |
| Gateway: 401 | Key marked, model-b never tried, llama answers | Same | Same |
| Llama: connection refused | Server marked, second llama model never tried, the gateway answers | Same | Same |
| Llama: read timeout (hung server) | The gateway answers (1 llama call) | The second llama model is tried and times out too; the call fails | As `:plan` |
| Llama: invalid output (escalation) | The bigger model on the same server answers; nothing marked | Same | Same |

**RubyLLM's fallbacks inside one entry**, for contrast (`with_fallbacks` on the entry's chat:
same context, key and base URL):

- **By model ID, a model outside RubyLLM's registry can't be a fallback.**
  `with_fallbacks("vendor-b/model-b")` resolves through the registry without
  `assume_model_exists`, so the gateway's 503 became `RubyLLM::ModelNotFoundError`. That class
  isn't a `RubyLLM::Error`, so it passed the transport's error mapping unmapped, and Sure's
  failover didn't treat it as a failure to move on from.
- **By `RubyLLM::Model` (`Model.default`, `:nodoc:`), model-b answered, and Sure saw model-a
  succeed.** The router, the result's route and the `.ai` event all named model-a with no error:
  no down mark, nothing for the health page or the footer line. The usage was model-b's tokens,
  priced as model-a. Only RubyLLM's `after_fallback` knew (from, to, the error).
- **The entry's settings carried over.** Model-b got model-a's strict schema. When model-b
  refused it with a 400 (not a fallback error), Sure's `auto` chain retried `json_object` on a
  new chat, which started again at model-a: four calls, two per model.

What it shows:

- **Marking the model, not the server, is what keeps a gateway usable** after one upstream fails.
  Under the plan as written, one model's 503 or upstream 429 takes every model on that gateway out
  for 60 seconds, for every feature.
- **Marking only the model is wrong for a hung local server:** the next model on the same process
  is tried and fails the same way, and "at most once" spends the move on it. `:location` passed
  every case except the whole-key 429, which needs a second move or a 429 that marks the key.
  Telling a key's 429 from an upstream's needs the gateway's error body, which isn't tested.
- **RubyLLM's fallbacks hide the failover from Sure.** To use them, Sure would need the
  `after_fallback` callback for marks, usage and the footer, `RubyLLM::Model` objects for unlisted
  models, and a rule for per-entry settings. Several entries on one endpoint do the same with
  none of that.
- **With no move limit, `:location` passed every case.** A list of four (gateway model-a and model-b
  both 429 on the whole key, llama refusing connections, a second gateway) reached the second
  gateway after three marks: two models, one server. The next call skipped all three without a
  request.
- **A family's own key, after the call by @josh-sanders:** one model's 503 moved to the family's other
  model on its key; its key's 401 stood as the error, with neither the local server nor the
  operator's key on another gateway tried (one request in all).
- **Not tested:** live gateways (OpenRouter, Vercel AI Gateway, Bedrock), a gateway's own fallback
  (OpenRouter's `models` list, Vercel's provider order, Bedrock's cross-region inference), streamed
  chat turns, and how the family admin is told.

## Lines of code for bill setup

Code lines only: blank and comment-only lines aren't counted.

| | Lines | What |
|---|---|---|
| Today | 559 | Both `BillSetupSuggester`s (137, 139), `Anthropic::Concerns::StructuredOutput` (37), both `UsageRecorder`s (93, 91), `Provider::Anthropic`'s structured-output helpers (16), and the two `suggest_bill_setup` methods (23, 23) |
| Shared by both new versions | 286 | `Transport::Base`, `Transport`, `Http`, `JsonMode`, `Ai::Error`, `Ai::Usage`, `Ai::Schema`, `Ai::Generation`, `SuggestBillSetup` and the prompt file |
| Hand-written `generate` | 97 | `HandWritten::Compatible` (45) and `HandWritten::Anthropic` (52), over `ruby-openai` and `anthropic` |
| RubyLLM `generate` | 123 | `Compatible` (36), `Anthropic` (33) and the shared `RubyLlmAdapter` (54), without their `converse` and `embed` code |

The redesign takes bill setup from 559 lines to 383 (hand-written) or 409 (RubyLLM). The JSON-mode
policy is Sure's in both versions and is counted once. RubyLLM's `converse` and `embed` add 51
adapter lines plus 47 for `Ai::Conversation`, against about 855 lines of today's chat transport.
Today's code does more (`previous_response_id`, usage recording), so treat that as context, not a
measurement.

## Small fixes in Sure's adapter

- `openai_use_system_role = true` on every compatible endpoint, OpenRouter's included: its
  provider reads the same setting. Otherwise RubyLLM sends system prompts with the `developer`
  role (`protocols/chat_completions/chat.rb:376-383`). The OpenRouter run first went out as
  `developer`, because the spike set it only for `:openai`; the free models answered anyway.
- Always pass `protocol:`. RubyLLM's OpenAI provider defaults to the Responses API.
- Set `openrouter_app_name` and `openrouter_app_url`. Otherwise OpenRouter sees "RubyLLM" and
  `https://rubyllm.com`.
- Check that `embed` returns one vector per text. 2.1.1 doesn't (#1269, fixed after the release).
- Check the turn deadline in the stream callback. Faraday's timeout is per read, so a stream that
  keeps trickling never trips it. Capping each request's timeout at the turn's remaining time
  would create a new cache key every call in RubyLLM's 64-entry connection cache.
- Send the final round with the tools still declared and `tool_choice: :none`.

## What to watch on upgrade

- **Pin exactly** (`gem "ruby_llm", "2.1.1"`). Releases are fast: 2.0.0 on 2026-09-18, 2.1.0 on
  10-08 and 2.1.1 on 10-11. About 47 issues were closed in the 17 days after 2.1.1. One
  maintainer has 1,752 commits; the next contributor has 138.
- **Use only the public API:** `RubyLLM.context`, `Chat#generate`, `#add_message`, the `with_*`
  setters, `Message#to_h`/`.new`, `RubyLLM::Tool` and `.embed`. If RubyLLM runs the tools,
  add `#run_tools`, `#waiting?`, `#pending_approvals`, `#before_tool_call` and
  `Tool.requires_approval`. The maintainer declines to open
  the loop's internals (#1291) and to add a supported opt-out from usage recording (#1071).
- **The railtie's side effects in Rails:**
  - It mixes `acts_as` into `ActiveRecord::Base`.
  - It sets `ActiveSupport::Notifications` as the instrumenter, so `*.ruby_llm` events publish
    in Sure's process.
  - It adds an `after_destroy` hook to every Active Storage blob, guarded by
    `ruby_llm_provider_files`.
  - It installs a usage ledger. Every call checks out a database connection and asks the schema
    cache whether `ruby_llm_usages` exists: no SQL after the first call in a process
    (`ruby_llm_usage_ledger_test`). Don't create that table. #1071 says not to rely on
    `Usage.ledger = nil`.
- **Usage counts.** RubyLLM's `input_tokens` excludes cached tokens; the raw APIs include them.
  Fixes after 2.1.1 change the counts: #1060 (Anthropic streaming input tokens), #1075 (zero
  input when cached exceeds prompt) and #1265 (vLLM cache writes).
- **Defaults Sure overrides,** in case they change: `max_retries`, `request_timeout`, the
  `developer` role, the Responses protocol as OpenAI's default, OpenRouter's app headers, and
  the Responses API's `store: false`.
- **Re-run** `bin/rails test test/models/ai`, then re-record with `SPIKE_RECORD=1` against live
  servers.

## Not judged in the spike

- Anthropic's and OpenAI's successful paths live, including the Responses API (both keys have
  no credits; vector stores ran, see "OpenAI vector stores with the sample statements"), and OpenRouter's paid chat models, such as Gemini, which
  need credits.
- The `auto` fallback chain against a live server that rejects strict schemas: none of the three
  local servers does any more.
- Gemini thought signatures through other gateways, such as LiteLLM.
- `RubyLLM.ocr`, which needs a Mistral or Cohere key.
- Web search, provider batches and explicit prompt caching, which Gemini's free tier refuses.
- Video: RubyLLM 2.1.1's registry model is retired, and Google's replacement isn't served for
  the call RubyLLM makes.
- Provider switches involving Nemotron on OpenRouter (the key's 50 free requests a day were used
  up).
- OCR: WeVisOne's two scan transcriptions, its `vips` direct extraction, 300 dpi, and Qwen's
  extraction from the `--special` transcriptions.
- Job runners: worker processes in separate processes (the two-worker runs shared one process),
  a Redis semaphore across workers, Sure's real generation jobs and batches instead of single
  calls, Puma under fiber isolation outside tests, a provider's real rate limits, and
  `async_http`'s connection reuse over TLS.
- llama-server's MTP and `--parallel` separately (they were changed together), `--parallel 2`,
  `--kv-unified` (and what it does when the shared context fills), and a larger embedding model
  or no `Nice=` ladder for the contention test.
- Interrupting: a PDF extraction or other long-prompt call, a chat with tool rounds interrupting
  between them, Ollama and LM Studio stopping on a closed connection, and streaming's own cost on
  throughput (382 s against 353 s, one run each).
- One full-suite run had a single failure that six reruns with other seeds didn't reproduce,
  most likely a timing check in `page_images_test` under heavy CPU load.
