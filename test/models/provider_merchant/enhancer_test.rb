require "test_helper"

class ProviderMerchant::EnhancerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Enhancer test", balance: 100, currency: "USD", accountable: Depository.new)
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
    use_ai_routes
  end

  def provider_merchant(name, **attributes)
    ProviderMerchant.create!(source: "lunchflow", name:, provider_merchant_id: "lf_#{name.parameterize}", **attributes).tap do |merchant|
      create_transaction(account: @account, name: "#{name} purchase", merchant:)
    end
  end

  # Answers each request with a website per merchant name in `urls` (nil when not listed).
  def stub_websites(urls)
    stub_ai(:enhance_merchants) do |request|
      ids = request.schema.dig(:properties, :merchants, :items, :properties, :merchant_id, :enum)
      { merchants: ids.map { |id| { merchant_id: id, business_url: urls[ProviderMerchant.find(id).name] } } }
    end
  end

  def enhance = perform_enqueued_jobs { ProviderMerchant::Enhancer.enhance_later(@family) }

  test "enhances provider merchants with their website and a logo" do
    merchant = provider_merchant("Walmart")
    requests = stub_websites("Walmart" => "walmart.com")

    enhance

    assert_equal "walmart.com", merchant.reload.website_url
    assert_equal "https://cdn.brandfetch.io/walmart.com/icon/fallback/lettermark/w/40/h/40?c=test_client_id", merchant.logo_url
    assert_includes requests.first.input, "Walmart"
  end

  test "sends one batch per job, sized by the model" do
    3.times { |i| provider_merchant("Shop #{i}") }
    requests = nil

    use_ai_model_settings(batch_size: 2)
    requests = stub_websites({})
    enhance

    assert_equal [ 2, 1 ], requests.map { _1.schema.dig(:properties, :merchants, :items, :properties, :merchant_id, :enum).size }
  end

  test "leaves merchants the model returns null for" do
    merchant = provider_merchant("Local Diner")
    stub_websites({})

    enhance

    assert_nil merchant.reload.website_url
  end

  test "a deadlock while merging duplicates leaves the website unsaved, so the retry still merges them" do
    merchant = provider_merchant("Walmart")
    enhancer = ProviderMerchant::Enhancer.new(@family)
    enhancer.stubs(:deduplicate_by_website).raises(ActiveRecord::Deadlocked)

    assert_raises(ActiveRecord::Deadlocked) do
      enhancer.apply_ai(Ai::Result.new(value: { merchants: [ { merchant_id: merchant.id, business_url: "walmart.com" } ] }))
    end
    assert_nil merchant.reload.website_url
  end

  test "deduplicates merchants by website" do
    lunchflow = provider_merchant("Walmart")
    ai_merchant = ProviderMerchant.create!(source: "ai", name: "Walmart", website_url: "walmart.com",
      logo_url: "https://cdn.brandfetch.io/walmart.com/icon/fallback/lettermark/w/40/h/40?c=test_client_id")
    duplicate = create_transaction(account: @account, name: "Walmart purchase 2", merchant: ai_merchant).transaction
    stub_websites("Walmart" => "walmart.com")

    enhance

    assert_equal "walmart.com", lunchflow.reload.website_url
    assert_equal lunchflow.id, duplicate.reload.merchant_id
  end

  test "a website another run saved first still merges this family's duplicates" do
    lunchflow = provider_merchant("Walmart")
    ai_merchant = ProviderMerchant.create!(source: "ai", name: "Walmart", website_url: "walmart.com")
    duplicate = create_transaction(account: @account, name: "Walmart purchase 2", merchant: ai_merchant).transaction
    enhancer = ProviderMerchant::Enhancer.new(@family)
    enhancer.ai_generation   # this run picks the merchant up while it has no website
    lunchflow.update_columns(website_url: "walmart.com")   # another family's run saves it first

    enhancer.apply_ai(Ai::Result.new(value: { merchants: [ { merchant_id: lunchflow.id, business_url: "walmart.com" } ] }))

    assert_equal lunchflow.id, duplicate.reload.merchant_id
  end

  test "a merchant another run gave a website before this run's next batch still has its duplicates merged" do
    lunchflow = provider_merchant("Walmart")
    ai_merchant = ProviderMerchant.create!(source: "ai", name: "Walmart", website_url: "walmart.com")
    duplicate = create_transaction(account: @account, name: "Walmart purchase 2", merchant: ai_merchant).transaction
    lunchflow.update_columns(website_url: "walmart.com")   # another family's run, between this run's batches

    continuation = ProviderMerchant::Enhancer.from_ai_job(family_id: @family.id, ids: [ lunchflow.id ])

    assert_nil continuation.ai_generation, "nothing left to ask the AI"
    assert_equal lunchflow.id, duplicate.reload.merchant_id
  end

  test "a website cleared between the check and the lock merges nothing" do
    lunchflow = provider_merchant("Walmart", website_url: "walmart.com")
    blank = provider_merchant("Corner Shop")   # no website, like every unenhanced merchant
    corner_purchase = blank.transactions.first
    ProviderMerchant.any_instance.stubs(:with_lock).with { true }.yields
    ProviderMerchant.any_instance.stubs(:website_url).returns(nil)   # another writer cleared it under the lock

    ProviderMerchant::Enhancer.from_ai_job(family_id: @family.id, ids: [ lunchflow.id ]).ai_generation

    assert_equal blank.id, corner_purchase.reload.merchant_id
  end

  test "a second run isn't queued while one holds the lock" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      assert ProviderMerchant::Enhancer.enhance_later(@family)
      assert_not ProviderMerchant::Enhancer.enhance_later(@family)
    end
  end

  test "makes no call when nothing needs a website, and releases the lock" do
    provider_merchant("Amazon", website_url: "amazon.com")
    Rails.stubs(:cache).returns(cache = ActiveSupport::Cache::MemoryStore.new)
    requests = stub_websites({})

    enhance

    assert_empty requests
    assert_not cache.exist?(ProviderMerchant::Enhancer.lock_key(@family))
  end

  # Issue #2925: a website that arrived before Brandfetch was configured left the merchant
  # without a logo, and the enhancer never selected it again.
  test "backfills logos for merchants that already have a website, without calling the model" do
    merchant = provider_merchant("Amazon", website_url: "amazon.com")
    merchant.update_column(:logo_url, nil)
    requests = stub_websites({})

    enhance

    assert_empty requests
    assert_equal "https://cdn.brandfetch.io/amazon.com/icon/fallback/lettermark/w/40/h/40?c=test_client_id", merchant.reload.logo_url
  end

  # A logo backfill failure is cosmetic and must not abort the run.
  test "a logo backfill failure does not prevent enhancement" do
    merchant = provider_merchant("Walmart")
    ProviderMerchant.stubs(:backfill_logos).raises(StandardError, "boom")
    stub_websites("Walmart" => "walmart.com")

    enhance

    assert_equal "walmart.com", merchant.reload.website_url
  end

  test "keeps a provider-supplied logo when adding the website" do
    merchant = provider_merchant("Binance", logo_url: "https://coinstats.app/binance.png")
    stub_websites("Binance" => "binance.com")

    enhance

    assert_equal "binance.com", merchant.reload.website_url
    assert_equal "https://coinstats.app/binance.png", merchant.logo_url
  end

  # Drift bug 3: a failed batch used to be skipped without a word.
  test "a failure is logged and releases the lock" do
    provider_merchant("Walmart")
    Rails.stubs(:cache).returns(cache = ActiveSupport::Cache::MemoryStore.new)
    stub_ai(:enhance_merchants, raises: Ai::Error::Refused.new("bad", status: 400))

    assert_difference -> { DebugLogEntry.where(category: "merchant_enhancement", level: "error").count }, 1 do
      enhance
    end
    assert_not cache.exist?(ProviderMerchant::Enhancer.lock_key(@family))
  end

  test "a run that can't be queued releases its lock and says so" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Ai::GenerationJob.stubs(:perform_later).returns(false)

    assert_raises(ActiveJob::EnqueueError) { ProviderMerchant::Enhancer.enhance_later(@family) }
    assert_not Rails.cache.exist?(ProviderMerchant::Enhancer.lock_key(@family))
  end

  test "a run whose enqueue raises releases its lock and raises EnqueueError, keeping the cause" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Ai::GenerationJob.stubs(:perform_later).raises(Redis::CannotConnectError, "queue down")

    error = assert_raises(ActiveJob::EnqueueError) { ProviderMerchant::Enhancer.enhance_later(@family) }
    assert_kind_of Redis::CannotConnectError, error.cause
    assert_not Rails.cache.exist?(ProviderMerchant::Enhancer.lock_key(@family))
  end

  test "each batch renews the lock, so a run longer than its TTL keeps it" do
    Rails.stubs(:cache).returns(cache = ActiveSupport::Cache::MemoryStore.new)
    provider_merchant("Walmart")
    stub_websites({})
    ProviderMerchant::Enhancer.enhance_later(@family)
    key = ProviderMerchant::Enhancer.lock_key(@family)

    travel ProviderMerchant::Enhancer::LOCK_TTL - 1.minute
    ProviderMerchant::Enhancer.new(@family, merchant_ids: []).ai_generation
    travel 2.minutes

    assert cache.exist?(key)
  end

  test "a queued run keeps its lock" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    assert ProviderMerchant::Enhancer.enhance_later(@family)
    assert Rails.cache.exist?(ProviderMerchant::Enhancer.lock_key(@family))
  end
end
