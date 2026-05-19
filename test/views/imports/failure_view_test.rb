# frozen_string_literal: true

require "test_helper"

class ImportsFailureViewTest < ActionView::TestCase
  test "renders import error details" do
    import = imports(:transaction)
    import.error = "Sure import preflight failed:\nCategory name \"Groceries\" already exists."

    render partial: "imports/failure", locals: { import: import }

    assert_includes rendered, "Sure import preflight failed:"
    assert_includes rendered, "Category name &quot;Groceries&quot; already exists."
  end
end
