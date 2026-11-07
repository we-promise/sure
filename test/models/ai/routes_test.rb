require "test_helper"

class Ai::RoutesTest < ActiveSupport::TestCase
  test "a shadow and document search take their needs from the feature they follow" do
    assert_equal Ai::Routes.needs_for(:categorize), Ai::Routes.needs_for(:shadow_categorize)
    assert_equal %i[embedding], Ai::Routes.needs_for(:search_documents)
    assert_equal :embed, Ai::Routes.source_of(:search_documents)
  end

  test "features share a consent row through consent_as, and a shadow keeps its own" do
    assert_equal :embed, Ai::Routes.consent_key(:search_documents)
    assert_equal :detect_merchants, Ai::Routes.consent_key(:enhance_merchants)
    assert_equal :shadow_categorize, Ai::Routes.consent_key(:shadow_categorize)
    assert_equal %i[chat bill_setup extract_pdf embed categorize detect_merchants], Ai::Routes.consent_keys
  end

  test "a shadow shows under its primary's row; routing through another feature doesn't move a row" do
    assert_equal :categorize, Ai::Routes.row_key(:shadow_categorize)
    assert_equal :embed, Ai::Routes.row_key(:search_documents)
    assert_equal :detect_merchants, Ai::Routes.row_key(:enhance_merchants)
    assert_equal :chat, Ai::Routes.row_key(:chat)
  end

  test "a consent row's manifest is everything its group sends" do
    assert_equal %i[transaction_names merchant_names], Ai::Routes.sends_for(:detect_merchants)
    assert_equal %i[depends_on_vector_store search_query], Ai::Routes.sends_for(:embed)
    assert_equal Ai::Routes.sends_for(:categorize), Ai::Routes.sends_for(:shadow_categorize)
  end

  test "an unknown feature raises" do
    assert_raises(KeyError) { Ai::Routes.fetch(:summarize) }
  end
end
