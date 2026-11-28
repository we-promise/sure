# Prompt: RubyLLM spike (PR 1 of the AI plumbing redesign)

You're running a one-week spike for Sure (`we-promise/sure`, Rails 8). It answers one question:
**should Sure's AI transports be thin adapters over the RubyLLM gem, or hand-written?** The
answer decides how PRs 2 (generations) and 3 (chat) of the AI plumbing redesign are built.
The spike is never merged. What matters is the evidence and a short note.

## Read first

- The design: `docs/proposals/v0.8/ai-plumbing-redesign.md` on the proposal branch (PR #4440).
  Read these sections closely:
  - §7: the transport interface and the JSON-mode strategy;
  - §9: `Ai::Error`;
  - §8.1: `Ai::Generation` and `SuggestBillSetup`;
  - §5.5 and §8.4: chat, bounded turns and `Ai::Conversation`;
  - §10: instrumentation;
  - §19: the spike, and the **RubyLLM spike criteria**, which are your checklist.

  Skim §4.2–4.3 (endpoints, models, presets) for the vocabulary.
- Today's code on `origin/main`:
  - `app/models/recurring_transaction/ai_setup_suggester.rb`;
  - `app/models/provider/{openai,anthropic}/bill_setup_suggester.rb`;
  - `app/models/provider/anthropic/concerns/structured_output.rb` and
    `Provider::Anthropic.structured_output_tool_choice` (#4513: models that can't be forced get
    `auto` plus one retry);
  - `app/models/assistant/function.rb` and `Assistant.function_classes`;
  - `app/models/vector_store/*`.
- RubyLLM: the latest release at the start, its source and its open issues. Write down the
  version you use.
- Chatwoot's move to RubyLLM is a useful precedent. Its PR #16078 kept audio transcription and
  embeddings on dedicated APIs. Find out why before you judge `embed`.

## Setup

- Make a fresh worktree from the latest `origin/main`, next to your Sure checkout:
  `git worktree add ../sure-ruby-llm-spike -b spike/ruby-llm origin/main`. Don't touch the
  checkout you started from or its current branch.
- Put keys and addresses in the worktree's `.env.local`, which git ignores. Never commit them,
  and never let them into cassettes: filter them with VCR. The spike reads only its own
  variables:
  `SPIKE_ANTHROPIC_API_KEY`, `SPIKE_OPENROUTER_API_KEY`, `SPIKE_LLAMA_CPP_URL` (chat, port
  8080), `SPIKE_LLAMA_CPP_EMBED_URL` (port 8081), `SPIKE_OLLAMA_URL` (default
  `http://localhost:11434`), `SPIKE_LMSTUDIO_URL` (default `http://localhost:1234`).
  If a value is missing, ask me for it. Don't guess hosts.
- Before writing code, check that each local server is reachable and list its loaded models
  (`/v1/models`; for llama.cpp also `/props`, to see whether `--jinja` tool calling is on).
  Record what's there. If a server is down, say so in the note and judge its rows from source.
- Commit to `spike/ruby-llm` as you go. Don't push or open a PR unless I ask.

## What to build

Build only what the criteria need, behind the §7 interface, under `app/models/ai/` as the plan
names it. Skip routing, consent, configuration tables, jobs and the sequencer. Use a hard-coded
endpoint and model struct, built from the spike's ENV, in place of `Ai::Config`.

1. **The shared pieces, small:**
   - `Ai::Transport::Base` with `Request` and `Response` as in §7, including
     `reasoning_effort`;
   - `Ai::Error` as in §9, and `Ai::Usage`;
   - `Ai::Transport::Http`, which resolves the proxy once (`HTTPS_PROXY`, `HTTP_PROXY`,
     `NO_PROXY`) and sets the endpoint's timeout and headers;
   - one `.ai` notification per call, and per tool step, carrying the prompt, output, usage
     and error.
2. **`generate`, both ways**, for `SuggestBillSetup` (the §8.1 shape: one prompt file, one
   schema, the same normalisation as `AiSetupSuggester`):
   - `Ai::Transport::Compatible` and `Ai::Transport::Anthropic` over RubyLLM;
   - the same two hand-written over the clients Sure already uses (`ruby-openai`, `anthropic`).

   Both follow §7's strategy table:
   - `strict` → `json_object` → `none`;
   - `auto` falls back when the null ratio is over 50% or a 400 comes back;
   - tolerant parsing (`<think>`, fenced JSON);
   - #4513's `auto` path for Anthropic models that can't be forced;
   - `reasoning_effort` sent by `Compatible` and dropped on the 400 retry.

   The two versions exist so the line comparison measures something real.
3. **`converse` over RubyLLM:** one streaming chat turn with one tool, wrapping an existing
   `Assistant::Function` (a read-only one, such as `get_accounts`). **Sure owns the tool
   loop.** The adapter must return the model's tool calls to `Ai::Conversation` rather than
   letting RubyLLM run them. Write a minimal `Ai::Conversation` loop with §5.5's two bounds:
   - `max_tool_rounds`, with the last round sent without tools;
   - the turn timeout.

   If RubyLLM can only run tools inside its own loop, that's the most important finding of
   the spike. Report it precisely, with the code path.
4. **`embed` over RubyLLM:** one call to the llama.cpp embedding server, returning vectors of
   the model's dimension.

## Test matrix (live, then recorded)

Record every live run as a VCR cassette under `test/vcr_cassettes/ai/<preset>/`. Write
minitest tests that replay them.

| Provider | `generate` | `converse` + streamed tool call | `embed` | Also prove |
|---|---|---|---|---|
| llama.cpp | yes | yes | yes (8081) | `<think>` stripping; `/v1` normalising; a timeout shorter than a slow request maps to `Ai::Error::Timeout` |
| LM Studio | yes | yes | — | strict schema rejected → `auto` fallback works |
| Ollama | yes | yes | if an embedding model is loaded | `/v1` normalising |
| Anthropic | one forced model and one `auto` model (see `FORCED_TOOL_CHOICE_MODELS`) | yes | — | #4513 retry; the proxy is honoured |
| OpenRouter | yes | a Gemini thinking model over two tool rounds | — | thought signatures survive the gateway |
| OpenAI direct | no key | no key | no key | Responses API and vector stores: judge from RubyLLM's source, docs and issues, and mark "not tested live" |

Also cover:

- **Unknown models:** use a model name missing from RubyLLM's registry (`assume_model_exists`).
- **Errors:** prove each mapping onto `Ai::Error` with a live call where you can get one (a bad
  key → `Unauthorized`, a refused port → `Unreachable`, an oversized prompt → `ContextTooLong`,
  in each provider's wording), and with WebMock otherwise (429, 5xx).
- **Retries and timeout:** RubyLLM's default `max_retries = 3` allows four attempts, each up
  to the full `request_timeout`, so one call can wait four timeouts plus backoff. Show that
  the endpoint's settings override both. Count the requests WebMock sees for a 429, a 5xx and
  a timeout.
- **Correlation id:** the job's arguments are the source of truth (§10). Try
  `RubyLLM.workflow(name, id:)`, re-entered in each job from those arguments (first confirm it
  exists in the release you pinned), and see whether RubyLLM's own events, one per tool step,
  can feed Sure's subscribers in place of Sure emitting its own. Report which approach needs
  less code and whether either loses anything: usage, route, error class, correlation id.
- **Proxy:** run every client through a local forward proxy and check `NO_PROXY`. Anthropic's
  client is the one that bypasses it today.
- **Langfuse:** if `LANGFUSE_*` is set in `.env.local`, check the traces. Otherwise check the
  `.ai` event payloads (prompt, output, one event per tool step) and mark the row "event level
  only".

## Order and stop rule

Work in this order:

1. `generate` on every provider;
2. who owns the tool loop;
3. errors, retries, timeout and proxy;
4. `converse` streaming on the local servers;
5. `embed`;
6. the rest.

A criterion that fails without a small fix ends the spike early with "not adopted". A small fix
means at most a day's work inside Sure's adapter, with no monkey-patch of the gem's internals
and no fork. Stop at one week whatever state you're in, and report what's unjudged.

## Deliverables

1. **The branch** `spike/ruby-llm`: the code, cassettes and tests, passing with
   `bin/rails test test/models/ai`.
2. **The note**: create `docs/llm-guides/ai-pipeline.md` with one section, "Transports:
   RubyLLM spike". It contains:
   - the decision, adopted or not, and the RubyLLM version;
   - a table with one row per §19 criterion: Pass, Small fix (what it is), Fail or Not tested
     live, each with its evidence (test name, cassette path, or a link to the gem's source or
     an issue at the pinned version);
   - lines of code for bill setup in three places: today's code (the two suggesters plus the
     shared concerns they use), the hand-written `generate`, and the RubyLLM `generate`;
   - if adopted, the pinned version and what the owner watches on upgrade. If not adopted, what
     a later attempt would need.
3. **A short summary back to me:**
   - the decision;
   - any criterion that failed or wasn't judged;
   - anything in the plan (§7, §8.1, §8.4, §9, §10) that the spike showed to be wrong or
     underspecified. Name the section and the change, and don't edit the plan.
