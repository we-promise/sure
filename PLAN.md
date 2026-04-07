# Plan: Refactor PDF Reconciliation Tool Calling

## Problem

PR #1382 introduces a `run_reconciliation_tool_loop` in `Provider::Openai::PdfProcessor` that manually orchestrates LLM tool/function calling: it loops up to 8 times, detects tool calls in raw responses, dispatches them to `GetAccounts`/`GetTransactions` functions in-process, and appends results back to the conversation — all at the OpenAI Chat Completions API level.

This duplicates the tool-calling orchestration already built into the assistant layer (`Assistant::Responder` + `Assistant::FunctionToolCaller`) and tightly couples `PdfProcessor` to OpenAI's raw API format. The existing assistant infrastructure already handles:
- Parsing function requests from LLM responses (`ChatFunctionRequest`)
- Executing functions via `FunctionToolCaller.fulfill_requests`
- Passing results back to the LLM for follow-up

## Architecture

The reconciliation flow is straightforward — **not** an unbounded multi-turn loop:

1. The LLM calls `get_accounts` to find a matching account for the statement
2. If a match is found, the LLM calls `get_transactions` to fetch synced transactions for comparison
3. The LLM produces the reconciliation result

This is at most **two rounds** of tool calls — the same one-shot pattern already implemented in `Assistant::Responder#handle_follow_up_response`. The LLM can even request both tools in a single round if prompted correctly.

Rather than building a new `ToolLoop` abstraction, we should reuse the existing tool-calling infrastructure directly. `PdfProcessor` just needs to:
1. Make an LLM call via the provider's `chat_response` (which returns parsed `ChatFunctionRequest` objects)
2. Execute those requests via `FunctionToolCaller.fulfill_requests`
3. Make one follow-up `chat_response` call with the results

This mirrors exactly what `Responder#handle_follow_up_response` already does, but synchronously and without streaming/events.

## Steps

### Step 1: Add a synchronous tool-call helper to `PdfProcessor`

**File:** `app/models/provider/openai/pdf_processor.rb`

Replace `run_reconciliation_tool_loop`, `execute_reconciliation_tool_call`, and `reconciliation_tools` with a method that uses the existing provider and function infrastructure:

```ruby
def run_reconciliation(pdf_text, effective_model)
  user = family&.users&.find_by(role: :admin) || family&.users&.first
  return nil unless user

  functions = [
    Assistant::Function::GetAccounts.new(user),
    Assistant::Function::GetTransactions.new(user)
  ]
  tool_caller = Assistant::FunctionToolCaller.new(functions)
  llm = Provider::Registry.get_provider(:openai)

  # First call: LLM analyzes PDF text and requests tools (get_accounts, get_transactions)
  response = llm.chat_response(
    reconciliation_prompt(pdf_text),
    model: effective_model,
    instructions: reconciliation_instructions,
    functions: tool_caller.function_definitions,
    family: family
  )
  raise response.error unless response.success?

  first_response = response.data
  return parse_reconciliation(first_response) if first_response.function_requests.empty?

  # Execute requested tools
  tool_calls = tool_caller.fulfill_requests(first_response.function_requests)

  # Follow-up call: LLM receives tool results, produces reconciliation
  follow_up = llm.chat_response(
    reconciliation_prompt(pdf_text),
    model: effective_model,
    instructions: reconciliation_instructions,
    functions: tool_caller.function_definitions,
    function_results: tool_calls.map(&:to_result),
    family: family
  )
  raise follow_up.error unless follow_up.success?

  parse_reconciliation(follow_up.data)
end
```

Key points:
- Uses `LlmConcept#chat_response` (provider-agnostic, not raw OpenAI API)
- Uses `FunctionToolCaller` for dispatch (no manual function routing by name)
- Two calls max: initial + follow-up with tool results (same as `Responder`)
- No loop needed — the LLM gets both tools, calls what it needs, gets one follow-up

### Step 2: Update `PdfProcessingResult` to include reconciliation

**File:** `app/models/provider/llm_concept.rb`

```ruby
PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data, :reconciliation)
```

### Step 3: Update `build_result` in `PdfProcessor`

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

### Step 4: Keep PR #1382's domain changes (job, import, views, locales)

The following changes from PR #1382 are domain-specific and correct — they should remain as-is:
- `ProcessPdfJob` — skip extraction when reconciliation matches
- `PdfImport` — `reconciliation_data`, `reconciliation_matched?`, `reconciliation_account` methods
- View changes (`_pdf_import.html.erb`, `_nav.html.erb`)
- Locale additions

### Step 5: Update tests

**File:** `test/models/provider/openai/pdf_processor_test.rb`

- Remove tests that assert on manual tool-call loop internals
- Test that `chat_response` is called with correct function definitions
- Test that `FunctionToolCaller.fulfill_requests` is used for tool dispatch
- Mock provider responses to return `ChatResponse` / `ChatFunctionRequest` objects

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `app/models/provider/openai/pdf_processor.rb` | **Modify** | Replace manual tool loop with provider-based `chat_response` + `FunctionToolCaller` |
| `app/models/provider/llm_concept.rb` | **Modify** | Add `:reconciliation` to `PdfProcessingResult` |
| `test/models/provider/openai/pdf_processor_test.rb` | **Modify** | Update tests for refactored reconciliation |

## Key Design Decisions

1. **No new abstraction needed**: The existing `chat_response` + `FunctionToolCaller` pattern is sufficient for a two-call flow. No `ToolLoop` class required.
2. **Provider-agnostic**: Uses `LlmConcept#chat_response` interface, not raw OpenAI API.
3. **Reuses existing `FunctionToolCaller`**: No new function execution code — same dispatch mechanism as the chat assistant.
4. **No changes to `Assistant::Function` classes**: `GetAccounts` and `GetTransactions` work as-is.
5. **Matches existing pattern**: The two-call flow (initial → execute tools → follow-up) mirrors `Responder#handle_follow_up_response` exactly.
