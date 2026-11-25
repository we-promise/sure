require "test_helper"

# Ties each background feature's `sends:` in Ai::Routes to what its payload builder
# hands the provider. A field the builder starts sending fails here until it is
# mapped to a declared item, and a declared item nothing sends fails too.
class AiProviderPayloadManifestTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  # What each field of each provider argument discloses. Record ids are opaque
  # and disclose nothing. Amounts go unsigned, so `classification` (income or
  # expense) is the only direction sent.
  FIELD_ITEMS = {
    transactions: {
      id: [],
      amount: %i[transaction_amounts],
      classification: %i[transaction_types],
      description: %i[transaction_names transaction_notes],
      merchant: %i[merchant_names]
    },
    user_categories: { id: [], name: %i[category_names], is_subcategory: %i[category_names], parent_id: %i[category_names] },
    user_merchants: { id: [], name: %i[merchant_names] },
    merchants: { id: [], name: %i[merchant_names] }
  }.freeze

  # Passed alongside the payload for prompt overrides and tracing; never sent.
  NOT_SENT = %i[family].freeze

  setup do
    use_ai_routes
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Manifest", balance: 100, currency: "USD", accountable: Depository.new)
    @merchant = ProviderMerchant.create!(source: "lunchflow", name: "Corner Shop", provider_merchant_id: "lf_corner")
    @entry = create_transaction(account: @account, name: "CORNER SHOP 123", notes: "milk for the office", merchant: @merchant)
    @category = @family.categories.create!(name: "Groceries")
    @llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
    Provider::Registry.stubs(:get_provider).returns(@llm_provider)
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
  end

  test "categorize sends exactly what it declares, and its shadow sends the same" do
    sent = capture(:auto_categorize) { Family::AutoCategorizer.new(@family, transaction_ids: [ @entry.transaction.id ]).auto_categorize }

    assert_description_carries_name_and_notes sent
    assert_equal declared(:categorize), items_in(sent)
    assert_nil Ai::Routes.fetch(:shadow_categorize)[:sends], "a shadow sends its primary's payload, so it declares none of its own"
  end

  test "detect_merchants sends exactly what it declares" do
    unassigned = create_transaction(account: @account, name: "CORNER SHOP 123", notes: "milk for the office")
    sent = capture(:auto_detect_merchants) { Family::AutoMerchantDetector.new(@family, transaction_ids: [ unassigned.transaction.id ]).auto_detect }

    assert_description_carries_name_and_notes sent
    assert_equal declared(:detect_merchants), items_in(sent)
  end

  test "enhance_merchants sends exactly what it declares" do
    sent = capture(:enhance_provider_merchants) { ProviderMerchant::Enhancer.new(@family).enhance }

    assert_equal declared(:enhance_merchants), items_in(sent)
  end

  private

    def capture(method)
      sent = nil
      @llm_provider.expects(method).with { |**kwargs| sent = kwargs }.returns(provider_success_response([]))
      yield
      sent
    end

    def items_in(sent)
      sent.except(*NOT_SENT).flat_map do |argument, rows|
        fields = FIELD_ITEMS.fetch(argument) { flunk "map the #{argument} argument in FIELD_ITEMS" }
        assert rows.any?, "#{argument} was empty, so its fields went unchecked"
        rows.flat_map(&:keys).uniq.flat_map do |field|
          fields.fetch(field) { flunk "map #{argument}.#{field} to what it discloses in FIELD_ITEMS" }
        end
      end.to_set
    end

    def declared(feature) = Ai::Routes.fetch(feature).fetch(:sends).to_set

    def assert_description_carries_name_and_notes(sent)
      description = sent.fetch(:transactions).first.fetch(:description)
      assert_includes description, "CORNER SHOP 123"
      assert_includes description, "milk for the office"
    end
end
