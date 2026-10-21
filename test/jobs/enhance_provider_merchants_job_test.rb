require "test_helper"

class EnhanceProviderMerchantsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @key = EnhanceProviderMerchantsJob.lock_key(@family)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(@key, true)
  end

  teardown { Rails.cache = @original_cache }

  test "holds the lock until the last batch finishes" do
    ProviderMerchant::Enhancer.any_instance.stubs(:batches).returns([ [ "a" ], [ "b" ] ])
    ProviderMerchant::Enhancer.any_instance.stubs(:enhance)

    assert_enqueued_jobs 2, only: EnhanceProviderMerchantsJob do
      EnhanceProviderMerchantsJob.perform_now(@family)
    end

    EnhanceProviderMerchantsJob.perform_now(@family, merchant_ids: [ "a" ])
    assert Rails.cache.exist?(@key)

    EnhanceProviderMerchantsJob.perform_now(@family, merchant_ids: [ "b" ])
    assert_not Rails.cache.exist?(@key)
  end

  test "releases the lock when there is nothing to enhance" do
    ProviderMerchant::Enhancer.any_instance.stubs(:batches).returns([])

    assert_no_enqueued_jobs { EnhanceProviderMerchantsJob.perform_now(@family) }
    assert_not Rails.cache.exist?(@key)
  end
end
