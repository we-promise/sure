# Adding a judgement

A decision model answers *typed questions about a state* and returns calibrated probabilities.
It does not generate text. Jev (TypeSafe) is the one Sure uses, and `categorize` the one feature
it answers, through `Ai::Judgements::CategorizeTransaction`. It runs on the same
plumbing as every LLM call ([AI pipeline](ai-pipeline.md)): a route entry, a transport over
RubyLLM, the usage path and failover.

If the model you are adding produces prose (chat replies, summaries, a merchant's website URL),
it's an LLM: write a generation instead.

## Why a judgement is its own class

A decision model can't do what an LLM route does: it emits a choice, not tokens. So its models
declare the `judge` capability, never `structured_output`, and the router keeps a judge model only
for a feature whose needs name a judgement (`needs: { generation: …, judgement: %i[judge] }` in
`Ai::Routes::MATRIX`). A Jev key can't end up serving chat or bill setup.

The feature's generation declares its judgement, and the generation's loop picks the class per
route:

```ruby
class Ai::Generations::CategorizeTransactions < Ai::Generation
  judged_by Ai::Judgements::CategorizeTransaction
end
```

On a `judge` route, the loop builds the judgement with the same slice of items, so batching, down
marks and failover stay in one place, and failover from Jev to an LLM switches class.

## The contract

```ruby
class Ai::Judgements::CategorizeTransaction < Ai::Judgement
  feature :categorize

  def initialize(transactions:, categories:, family:)   # the generation's #arguments
  def questions          # { category: { type: :choice, instructions:, options: { name => hint } } }
  def states             # { transaction id => { description:, amount:, … } }
  def value_from(answers) # the generation's value, from { id => { category: RubyLLM::Choice } | nil }
end
```

- **One state per request, many questions per state.** Jev bills almost entirely for the state
  and the option lists: measured against Jev, five questions cost 1.31× one. When a task needs
  another answer about the same item, add a question to the existing call rather than a call.
- **The generation's value shape.** `value_from` returns exactly what the generation returns
  (for categorize, `{ categorizations: [{ transaction_id:, category_name:, confidence:,
  probabilities: }] }`), so the requester doesn't know which model answered.
- **Questions are plain data.** RubyLLM 2.1.1 evaluates a Proc in a builder that inherits from
  `Object`, so an option named like a Kernel method would call it; the transport refuses a Proc.
- **A malformed answer fails its item.** RubyLLM rejects an answer with no confidence or an
  option that wasn't asked; that item comes back `nil` and is left out. All malformed raises
  `Ai::Error::InvalidOutput`.

## The three question types

| Type | Asks | RubyLLM answer |
| --- | --- | --- |
| `choice` | pick one of these options | `Choice#choice`, `#probabilities`, `#confidence` |
| `score` | position on an ordered rubric | `Score#score`, `#probabilities`, `#confidence` |
| `probability` | is this statement true (Jev's `noul`) | `Probability#probability` |

### Always give Choice an opt-out

A `choice` question **always** returns one of its options. Offer only real categories and a
transaction matching none of them still gets one. Add an explicit sentinel and translate it back
to `nil`:

```ruby
UNCATEGORIZED = "__uncategorized__"
options[UNCATEGORIZED] = "No listed category is a reasonable fit"
```

An opaque `ACH DEBIT 4471920 REF#88213` descriptor selects the sentinel at probability 1.0.
Without it, that row would have been assigned a real category at low confidence.

## Confidence and the threshold

The family's confidence threshold gates only answers from a model with `calibrated_confidence`:
cloud Jev has it; a self-hosted judge (`jev_local`) doesn't until an
admin has checked its confidence against agreement. The requester reads it off the result's
route. Clamp a reported confidence to 0..1: the threshold is in that range, and an out-of-range
value would clear any threshold.

## You are second in a cascade

`Family#auto_categorize_transactions` runs `Family::BayesCategorizer` first, a naive Bayes model
trained on the family's own history, and only what it declines reaches the generation. A decision
model receives the hard tail, so accuracy over a whole golden dataset overstates what it adds in
production; the number that matters is accuracy on the subset Bayes declines. Bayes's own `0.7`
and the family threshold's default `0.7` coincide by accident; don't share a constant.

## Endpoints, gateways and disclosure

The Jev endpoint comes from `JEV_API_KEY`, `JEV_ENDPOINT` and `JEV_MODEL` (or their
settings), read by `Ai::LegacyEnvConfig::Jev`. Which model categorizes is one instance-wide
choice, `Setting.categorization_provider`, which `CATEGORIZATION_PROVIDER` overrides.

- **Paths.** RubyLLM 2.1.1's `typesafe` provider posts to `<base>/v1/systemone`, so only
  TypeSafe-style endpoints are reachable. OpenRouter's decisions gateway needs RubyLLM 2.2
  (crmne/ruby_llm#1264); any other path isn't supported. Both are left out of the config with a warning, and the
  settings form refuses them.
- **Disclosure.** Default to the vendor's own API. When the endpoint is another host, the
  settings panel says so (`Ai::LegacyEnvConfig::Jev.effective_proxied?`, `.effective_host`):
  telling someone their transactions go to TypeSafe is wrong when they pass through another
  server first.
- **No borrowed keys.** An operator holding an unrelated `OPENROUTER_API_KEY` mustn't find Jev
  silently enabled.
- **https for cloud, http for local.** An http endpoint is a server on a private network
  (`jev_local`), sent one request at a time unless `JEV_CONCURRENCY` says otherwise.

## Concurrency

One state per request makes a batch a batch of requests. They're independent and latency-bound,
so `Ai::Transport::Jev` runs them on a pool of the endpoint's `parallel_requests` (8 on cloud Jev,
1 on a local server). Each pool thread re-enters the call (`Ai::CallContext.within`), so every
request writes its usage row with the call's id. Retries are the transport's (`attempt`), as for
every call.

## Evals

`Eval::ProviderFactory#build_jev` builds an `Eval::GenerationClient` on a Jev endpoint, so an eval
runs the judgement and transport production runs, and records each answer's confidence.

```bash
JEV_API_KEY=... PROVIDER=jev bin/rails "evals:run[categorization_golden_v2,jev-latest]"
```

Check `error_rate` before believing an accuracy figure: a stale model slug records every sample
as incorrect and otherwise reads as a credible 0%.

## Tests

- `stub_ai` answers a judge route by item id:
  `stub_ai(:categorize) { |request| request.states.keys.index_with { { category: [ "Coffee", 0.9 ] } } }`.
- `test/architecture/ai_transport_judge_test.rb` stubs the System One endpoint with WebMock.
- `test/models/ai/live/judge_live_test.rb` replays OpenCode Zen's free Jev; record with
  `RECORD_CASSETTES=1` and `JEV_LIVE_API_KEY` set to OpenCode Zen's anonymous key, `public`.

## Checklist

- [ ] An `Ai::Judgement` subclass with `feature`, `questions`, `states` and `value_from`
- [ ] The generation declares `judged_by` and defines `#arguments`
- [ ] The feature's `needs` in `Ai::Routes::MATRIX` name a judgement
- [ ] Every Choice has an opt-out, translated to `nil`
- [ ] Confidence clamped to 0..1; the threshold gates only `calibrated_confidence` models
- [ ] `test/models/ai/judgements/<name>_test.rb`
