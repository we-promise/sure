# Plan: Refactor PDF Reconciliation Tool Calling

## Problem

PR #1382 introduces a `run_reconciliation_tool_loop` in `Provider::Openai::PdfProcessor` that manually orchestrates LLM tool/function calling: it loops up to 8 times, detects tool calls in raw responses, dispatches them to `GetAccounts`/`GetTransactions` functions in-process, and appends results back to the conversation — all at the OpenAI Chat Completions API level.

This duplicates the tool-calling orchestration already built into the assistant layer (`Assistant::Responder` + `Assistant::FunctionToolCaller`) and tightly couples `PdfProcessor` to OpenAI's raw API format. The existing assistant infrastructure already handles:
- Parsing function requests from LLM responses (`ChatFunctionRequest`)
- Executing functions via `FunctionToolCaller.fulfill_requests`
- Passing results back to the LLM for follow-up

The fix is to extract a reusable tool-calling loop from the existing assistant infrastructure so `PdfProcessor` can delegate tool orchestration rather than reimplementing it.

## Architecture

The current assistant layer has a **one-shot** tool-call design (`Responder` calls the LLM, executes tools once, calls LLM again with results — no further recursion). The PDF reconciliation needs a **multi-turn** loop (up to N iterations). Rather than making `Responder` itself support multi-turn (it's tied to chat streaming/events), we'll create a lightweight, synchronous tool-calling loop that both contexts can use.

## Steps

### Step 1: Create `Assistant::ToolLoop` — a reusable synchronous tool-calling loop

**New file:** `app/models/assistant/tool_loop.rb`

This class encapsulates the "call LLM → detect tool requests → execute tools → feed results back → repeat" loop in a provider-agnostic way. It operates synchronously (no streaming) and supports a configurable max-iterations cap.

```ruby
class Assistant::ToolLoop
  DEFAULT_MAX_ITERATIONS = 8

  def initialize(llm:, function_tool_caller:, max_iterations: DEFAULT_MAX_ITERATIONS)
    @llm = llm
    @function_tool_caller = function_tool_caller
    @max_iterations = max_iterations
  end

  # Runs the tool loop synchronously.
  # Returns the final ChatResponse (with no remaining function_requests).
  def run(prompt:, model:, instructions: nil, family: nil)
    function_results = []
    iterations = 0
    response = nil

    loop do
      break if iterations >= @max_iterations

      provider_response = @llm.chat_response(
        prompt,
        model: model,
        instructions: instructions,
        functions: @function_tool_caller.function_definitions,
        function_results: function_results,
        family: family
      )

      raise provider_response.error if !provider_response.success?
      response = provider_response.data

      break if response.function_requests.empty?

      tool_calls = @function_tool_caller.fulfill_requests(response.function_requests)
      function_results = tool_calls.map(&:to_result)
      iterations += 1
    end

    response
  end
end
```

Key properties:
- Uses the existing `LlmConcept#chat_response` interface (provider-agnostic)
- Uses the existing `FunctionToolCaller` for dispatching (no manual function routing)
- Returns the final `ChatResponse` with the LLM's text answer
- Capped iterations prevent runaway spend

### Step 2: Refactor `PdfProcessor` to use `Assistant::ToolLoop`

**File:** `app/models/provider/openai/pdf_processor.rb`

Changes:
1. **Remove** `run_reconciliation_tool_loop` and `execute_reconciliation_tool_call` methods
2. **Remove** `reconciliation_tools` method that manually builds tool definitions
3. **Add** a method that instantiates an `Assistant::ToolLoop` with the appropriate functions and calls `run`
4. The reconciliation prompt/instructions stay in `PdfProcessor` (that's domain-specific and belongs here)

The `PdfProcessor` needs access to a `family` to instantiate `Assistant::Function::GetAccounts` and `GetTransactions` (they require a `user`). The PR already passes `family` into `PdfProcessor`. We'll use `family.users.first` (or an admin) as the `tool_user`, consistent with the PR's existing approach.

```ruby
def run_reconciliation(prompt, effective_model)
  user = family&.users&.find_by(role: :admin) || family&.users&.first
  return nil unless user

  functions = [
    Assistant::Function::GetAccounts.new(user),
    Assistant::Function::GetTransactions.new(user)
  ]

  tool_caller = Assistant::FunctionToolCaller.new(functions)

  # We need an LLM provider instance — we already have `client` but need
  # a Provider::Openai instance. Since PdfProcessor is already inside the
  # Openai namespace and receives the client, we construct a lightweight
  # wrapper or reuse the provider from the registry.
  llm = Provider::Registry.get_provider(:openai)

  loop = Assistant::ToolLoop.new(
    llm: llm,
    function_tool_caller: tool_caller,
    max_iterations: 8
  )

  loop.run(
    prompt: prompt,
    model: effective_model,
    instructions: reconciliation_instructions,
    family: family
  )
end
```

### Step 3: Update `PdfProcessingResult` to include reconciliation

**File:** `app/models/provider/llm_concept.rb`

```ruby
PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data, :reconciliation)
```

Add `:reconciliation` field with a default of `nil` (via `Data.define` keyword init).

### Step 4: Update `build_result` in `PdfProcessor`

Pass the reconciliation data from the tool loop response into the `PdfProcessingResult`:

```ruby
def build_result(parsed, reconciliation: nil)
  PdfProcessingResult.new(
    summary: parsed["summary"],
    document_type: normalize_document_type(parsed["document_type"]),
    extracted_data: parsed["extracted_data"] || {},
    reconciliation: reconciliation
  )
end
```

### Step 5: Keep PR #1382's domain changes (job, import, views, locales)

The following changes from PR #1382 are domain-specific and correct — they should remain as-is:
- `ProcessPdfJob` — skip extraction when reconciliation matches
- `PdfImport` — `reconciliation_data`, `reconciliation_matched?`, `reconciliation_account` methods
- View changes (`_pdf_import.html.erb`, `_nav.html.erb`)
- Locale additions

### Step 6: Update tests

**File:** `test/models/provider/openai/pdf_processor_test.rb`

- Remove tests that assert on manual tool-call loop internals
- Add tests that verify `Assistant::ToolLoop` is used
- Mock `Assistant::ToolLoop#run` to return expected reconciliation data

**New file:** `test/models/assistant/tool_loop_test.rb`

- Test the loop terminates when no function_requests
- Test the loop executes tools and passes results back
- Test the loop respects max_iterations
- Test error propagation

### Step 7: Optionally refactor `Assistant::Responder` to use `ToolLoop`

`Responder#handle_follow_up_response` currently does a single-shot tool call + follow-up. It could be refactored to delegate to `ToolLoop` for the non-streaming path, but this is a separate concern and can be deferred. The streaming requirement in `Responder` makes this non-trivial — note this as a future improvement.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `app/models/assistant/tool_loop.rb` | **Create** | Reusable synchronous tool-calling loop |
| `app/models/provider/openai/pdf_processor.rb` | **Modify** | Replace manual tool loop with `Assistant::ToolLoop` |
| `app/models/provider/llm_concept.rb` | **Modify** | Add `:reconciliation` to `PdfProcessingResult` |
| `test/models/assistant/tool_loop_test.rb` | **Create** | Tests for the new tool loop |
| `test/models/provider/openai/pdf_processor_test.rb` | **Modify** | Update tests for refactored reconciliation |

## Key Design Decisions

1. **Separate class vs. extending Responder**: `Responder` is tightly coupled to streaming and chat events. A separate `ToolLoop` is simpler and more reusable.
2. **Provider-agnostic**: `ToolLoop` uses the `LlmConcept#chat_response` interface, so it works with any provider (OpenAI, custom, future providers).
3. **Reuses existing `FunctionToolCaller`**: No new function execution code — the same dispatch mechanism used by the chat assistant.
4. **No changes to `Assistant::Function` classes**: `GetAccounts` and `GetTransactions` work as-is.
