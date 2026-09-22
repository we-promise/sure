require "test_helper"

class PluggyTransactionHashTest < ActiveSupport::TestCase
  include PluggyTransactionHash

  test "hash is stable for the same fields" do
    tx = { "id" => "t1", "amount" => 100, "currencyCode" => "BRL", "date" => "2026-01-01", "merchant" => "M", "description" => "D" }
    assert_equal content_hash_for_transaction(tx), content_hash_for_transaction(tx.dup)
  end

  test "hash changes when amount changes" do
    base = { "id" => "t1", "amount" => 100, "currencyCode" => "BRL", "date" => "2026-01-01", "merchant" => "M", "description" => "D" }
    refute_equal content_hash_for_transaction(base), content_hash_for_transaction(base.merge("amount" => 200))
  end
end
