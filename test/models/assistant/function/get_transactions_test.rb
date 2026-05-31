require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::GetTransactions.new(@user)
  end

  test "has correct name" do
    assert_equal "get_transactions", @function.name
  end

  # Regression for #1611: some LLM/tool clients (notably local models via Ollama)
  # serialize array arguments as JSON-encoded strings (e.g. "[\"Travel\"]") instead
  # of real arrays. coerce_arguments must decode them back into arrays.
  test "coerce_arguments decodes JSON-string array params into arrays" do
    coerced = @function.coerce_arguments(
      "page" => 1,
      "categories" => "[\"Food & Drink\"]",
      "merchants" => "[\"Amazon\", \"Costco\"]"
    )

    assert_equal [ "Food & Drink" ], coerced["categories"]
    assert_equal [ "Amazon", "Costco" ], coerced["merchants"]
    assert_equal 1, coerced["page"], "non-array params must be left untouched"
  end

  test "coerce_arguments leaves real arrays and scalar params untouched" do
    coerced = @function.coerce_arguments(
      "categories" => [ "Food & Drink" ],
      "search" => "mcdonalds",
      "page" => 2
    )

    assert_equal [ "Food & Drink" ], coerced["categories"]
    assert_equal "mcdonalds", coerced["search"]
    assert_equal 2, coerced["page"]
  end

  test "coerce_arguments wraps a bare (non-JSON) string array param into a single-element array" do
    coerced = @function.coerce_arguments("categories" => "Food & Drink")
    assert_equal [ "Food & Drink" ], coerced["categories"]
  end

  test "coerce_arguments is a no-op for non-hash input" do
    assert_nil @function.coerce_arguments(nil)
    assert_equal "x", @function.coerce_arguments("x")
  end

  # Regression for #1611: the chat path used to raise
  # "undefined method '&' for an instance of String" inside Transaction::Search.
  test "FunctionToolCaller fulfills a request whose array arg arrives as a JSON string" do
    caller = Assistant::FunctionToolCaller.new([ @function ])

    request = Provider::LlmConcept::ChatFunctionRequest.new(
      id: "call_1",
      call_id: "call_1",
      function_name: "get_transactions",
      function_args: { order: "desc", page: 1, categories: "[\"Food & Drink\"]" }.to_json
    )

    tool_calls = nil
    assert_nothing_raised do
      tool_calls = caller.fulfill_requests([ request ])
    end

    # function_result is persisted through a jsonb column, so keys come back as
    # strings — read it via indifferent access to stay agnostic to that.
    result = tool_calls.first.function_result.with_indifferent_access
    assert_kind_of Array, result[:transactions]
  end

  # The JSON-string form must behave identically to the real-array form.
  test "string-encoded and array-encoded category filters return the same results" do
    string_args = @function.coerce_arguments(
      "order" => "desc", "page" => 1, "categories" => "[\"Food & Drink\"]"
    )
    array_args = @function.coerce_arguments(
      "order" => "desc", "page" => 1, "categories" => [ "Food & Drink" ]
    )

    assert_equal @function.call(array_args)[:total_results],
                 @function.call(string_args)[:total_results]
  end
end
