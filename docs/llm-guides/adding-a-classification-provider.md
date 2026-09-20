# Adding a Classification Provider

A classification provider answers *typed questions about a state* and returns
calibrated probabilities. It does not generate text. `Provider::Jev` (TypeSafe)
is the reference implementation.

If the provider you are adding produces prose — chat replies, summaries, a
merchant's website URL — it is an LLM provider, not a classification provider.
Read [provider sync guidance](providers.md) and `Provider::LlmConcept` instead.

## Why this is separate from `:llm`

`Provider::Registry.preferred_llm_provider` returns the first LLM provider that
holds credentials, and every caller assumes the result can do everything an LLM
does. A classification provider cannot satisfy `#chat_response` or
`#process_pdf` — not "has not implemented them yet", but *cannot*, because it
emits a choice rather than tokens.

Registering one under `:llm` would therefore let a Jev API key route **chat**
traffic to something physically unable to serve it. So classification providers
live under their own registry concept:

```ruby
# app/models/provider/registry.rb
CONCEPTS = %i[exchange_rates securities llm property_valuations classification]

when :classification
  %i[jev]
```

OpenAI and Anthropic stay under `:llm`. They can categorize, but they cannot
answer typed questions, so they do not belong to a concept whose contract is
`#decide`. The eval runner builds them by name when benchmarking.

## The contract: one `#decide`, many questions

`Provider::ClassificationConcept` defines a single primitive:

```ruby
def decide(state:, questions:, model: "", family: nil)
```

- `state` — String, Hash or Array describing the thing being decided about
- `questions` — a Hash of question key => question definition
- returns a `DecisionSet`

**There is deliberately no method per task.** The provider bills almost entirely
for shipping the state and the option lists, not for the questions asked about
them. Measured against Jev, **five questions cost 1.31× one question**. A
`classify` / `score` / `judge` trio would force three round trips and pay for
the state three times over.

So when you add a task, batch its questions into an existing `#decide` call
where one is already being made for that state, rather than adding a call.

## The three question types

| Type | Asks | Returns |
| --- | --- | --- |
| `choice` | pick one of these options | the selected key, full distribution, confidence |
| `score` | position on an ordered rubric | float against a `legend`, distribution, confidence |
| `noul` | is this statement true | probability 0.0–1.0 |

```ruby
provider.decide(
  state: { description: "SQ *BLUE BOTTLE COFFEE", amount: 6.75 },
  questions: {
    category: {
      type: "choice",
      instructions: "Which spending category best fits this bank transaction?",
      criteria: { "Groceries" => nil, "Coffee" => "Subcategory of Restaurants" }
    }
  }
)
```

Read answers off the `DecisionSet`:

```ruby
set[:category].value          # => "Coffee"
set[:category].confidence     # => 0.97
set[:category].probabilities  # => { "Coffee" => 0.97, "Groceries" => 0.03 }
set.usage                     # => { "input_tokens" =>, "output_tokens" =>, "cost" => }
```

`noul` reports no separate confidence — the probability *is* the answer — so
`Provider::Jev` derives one from distance off the midpoint (0.5 is maximal
uncertainty).

### Always give Choice an opt-out

A `choice` question **always** returns one of the keys it was given. Offer only
real categories and a transaction matching none of them still gets one, because
the model has nowhere else to put it. Add an explicit sentinel and translate it
back to `nil` at the boundary:

```ruby
UNCATEGORIZED = "__uncategorized__"
criteria[UNCATEGORIZED] = "No listed category is a reasonable fit"
```

Verified behaviour: an opaque `ACH DEBIT 4471920 REF#88213` descriptor selects
the sentinel at probability 1.0. Without it, that row would have been assigned a
real category at low confidence.

The same applies to conditional questions. Asking "what kind of recurring charge
is this?" about a one-off coffee still returns an answer — so only *consume* it
for rows something else has already established are recurring.

## Structural compatibility with the LLM shapes

`CategoryDecision` responds to `#transaction_id` and `#category_name`, exactly
like `Provider::LlmConcept::AutoCategorization`. That is deliberate:
`Family::AutoCategorizer` and the eval runners consume either shape unchanged
and ignore the extra `confidence` / `probabilities` / `usage` fields.

Keep that property when adding types. A caller should not need to know which
kind of provider served it.

## You are second in a cascade

A classification provider does not see the transaction stream. `Family#auto_categorize_transactions`
runs `Family::BayesCategorizer` first — a pure-Ruby naive Bayes model trained on
the family's own categorized history, costing nothing and calling nobody — and
only the transactions it declines reach `Family::AutoCategorizer`, where your
provider sits:

```ruby
# app/models/family.rb
bayes_result = Family::BayesCategorizer.new(self).classify_and_apply(transaction_ids)
remaining_ids = Array(transaction_ids) - bayes_result.categorized_ids
# ... if remaining_ids is empty, no provider is called at all
llm_modified_count = AutoCategorizer.new(self, transaction_ids: remaining_ids).auto_categorize
```

Two consequences worth internalising before you benchmark anything.

**Your provider receives the hard tail.** Bayes takes the repeat merchants and
the obvious descriptors; what reaches you is what a model trained on this
family's own history could not place. Accuracy measured over a whole golden
dataset therefore *overstates* what your provider contributes in production,
because it credits you for rows you would never have been handed. The number
that matters is accuracy on the subset Bayes declines.

**Your confidence threshold is the second one in series.** `BayesCategorizer::CONFIDENCE_THRESHOLD`
is a hardcoded `0.7`; `families.categorization_confidence_threshold` also
defaults to `0.7`, derived independently from a golden-set sweep. That the two
coincide is a coincidence — different models over different distributions.
Do not extract them into a shared constant.

## Provider resolution

Categorization resolves through the family, not a global Setting — the choice
decides whose transaction descriptions leave the instance, the same reason
`assistant_type` lives on `Family`:

```ruby
# app/models/family.rb
def resolved_categorization_provider
  jev = Provider::Registry.get_provider(:jev) if effective_categorization_provider == "jev"
  jev || Provider::Registry.preferred_llm_provider
end
```

Credentials alone never switch a classification provider on, and the preview
flag plays no part here — it gates whether the *selector* is offered (see
[preview-feature gating](gating-a-preview-feature.md)), never what runs. A
family that opted into preview and then chose the AI provider gets the AI
provider.

Anything that needs to name the provider — the rule confirmation screen's cost
estimate, for instance — must call this same method rather than resolving
separately, or the screen will quote a provider that will not run.

## Endpoints, gateways and disclosure

Default to the vendor's own API. Gateways (OpenRouter and similar) serve an
identical payload, so one class covers both, but routing a family's financial
data through an extra party is something an operator opts into:

```ruby
DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
VENDOR_HOST      = "api.typesafe.ai"
```

When an operator points `JEV_ENDPOINT` at a gateway, the settings disclosure has
to say so — `Provider::Jev.effective_proxied?` and `.effective_host` exist for
exactly that. Telling someone their bank descriptions go to TypeSafe is wrong
when they transit a proxy first.

Require an explicit key with no fallback to another provider's credentials. An
operator holding an unrelated `OPENROUTER_API_KEY` should not find
classification silently enabled and billing them.

## Concurrency

One state per request means a batch of transactions is a batch of requests.
They are independent and latency-bound, so they run on a bounded pool — matching
the fan-out idiom in `Security::Provided`:

```ruby
pool = Concurrent::FixedThreadPool.new([ @concurrency, items.size ].min)
items.map { |item| Concurrent::Promises.future_on(pool) { ... } }.map(&:value!)
```

Bounded, not `Promises.future` alone: this fans out per transaction, so an
unbounded pool would open a socket per row. `value!` re-raises a worker's
exception so a failed request surfaces through `with_provider_response` rather
than landing as a `nil`.

One Faraday gotcha: `faraday-retry` only retries `IDEMPOTENT_METHODS`, which
excludes POST, and `retry_statuses` is never consulted because `raise_error`
converts the status to an exception first. Both have to be overridden or the
backoff silently never runs.

## Evals

`Eval::ProviderFactory` builds the provider for a run, taking per-run overrides
the registry deliberately does not accept. Add a branch there — both
`Eval::Runners::Base` and `Eval::Langfuse::ExperimentRunner` go through it.

A classification provider spending one request per sample can attribute cost per
sample, which is what makes `cost_per_sample` meaningful. Carry `usage` on the
returned struct so the runner can record it.

```bash
JEV_API_KEY=... PROVIDER=jev bin/rails "evals:run[categorization_golden_v2,jev-latest]"
```

Check `error_rate` before believing an accuracy figure — a stale model slug
records every sample as incorrect and otherwise reads as a credible 0%.

## Checklist

- [ ] `include ClassificationConcept`, implement `#decide`
- [ ] Register under `:classification`, not `:llm`
- [ ] Explicit API key, no fallback to another provider's credentials
- [ ] Default endpoint is the vendor's own; disclosure names the configured host
- [ ] Every Choice question has an opt-out sentinel, translated to `nil`
- [ ] Return types structurally compatible with the `LlmConcept` equivalents
- [ ] Per-request `usage` carried through for eval cost attribution
- [ ] Branch added to `Eval::ProviderFactory`
- [ ] Tests stub HTTP with WebMock — the suite blocks real connections
