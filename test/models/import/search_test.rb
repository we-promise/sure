require "test_helper"

class Import::SearchTest < ActiveSupport::TestCase
  setup do
    @scope = families(:dylan_family).imports
  end

  test "returns the whole scope when no filter is set" do
    assert_equal @scope.ids.sort, Import::Search.new(@scope).imports_scope.ids.sort
  end

  test "status keeps imports in that status" do
    results = Import::Search.new(@scope, filters: { status: "complete" }).imports_scope

    assert_includes results, imports(:pdf_processed)
    assert results.all?(&:complete?)
  end

  test "type keeps imports of that type" do
    results = Import::Search.new(@scope, filters: { type: "PdfImport" }).imports_scope

    assert_includes results, imports(:pdf)
    assert results.all? { |import| import.type == "PdfImport" }
  end

  test "status and type combine" do
    results = Import::Search.new(@scope, filters: { status: "pending", type: "PdfImport" }).imports_scope

    assert_includes results, imports(:pdf)
    assert_not_includes results, imports(:pdf_processed)
    assert_not_includes results, imports(:transaction)
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where.not(id: imports(:pdf_processed).id)

    assert_empty Import::Search.new(narrowed, filters: { status: "complete", type: "PdfImport" }).imports_scope
  end
end
