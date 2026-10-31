require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/sure/sorted_list")

class RuboCop::Cop::Sure::SortedListTest < ActiveSupport::TestCase
  test "accepts a marked list in alphabetical order" do
    assert_empty offenses(<<~RUBY)
      # sorted
      PROVIDERS = %w[akahu plaid simplefin].freeze

      # sorted
      enum :source, {
        akahu: "akahu",
        plaid: "plaid"
      }
    RUBY
  end

  test "flags the first entry out of order in a marked array or hash" do
    found = offenses(<<~RUBY)
      # sorted
      PROVIDERS = %w[plaid akahu simplefin].freeze

      # sorted
      enum :source, { plaid: "plaid", fio: "fio", up: "up" }
    RUBY

    assert_equal [ [ 2, "akahu", "plaid" ], [ 5, "fio", "plaid" ] ],
                 found.map { |offense| [ offense.line, *offense.message.scan(/`(\w+)`/).flatten ] }
  end

  test "leaves unmarked lists and lists nested in a marked one alone" do
    assert_empty offenses(<<~RUBY)
      PROVIDERS = %w[plaid akahu].freeze

      # sorted
      LIMITS = { akahu: %i[z a], plaid: %i[y b] }

      # not sorted on purpose
      ORDER = %w[plaid akahu]
    RUBY
  end

  test "checks each list in the repository it marks" do
    marked = %w[app/models/data_enrichment.rb app/models/provider_merchant.rb app/models/transaction.rb
                app/models/family/financial_data_reset.rb]

    marked.each do |path|
      source = Rails.root.join(path).read
      assert_match(/^\s*# sorted$/, source, "#{path} marks its list")
      assert_empty offenses(source), path
    end
  end

  private

    def offenses(source)
      config = RuboCop::Config.new({ "Sure/SortedList" => { "Enabled" => true } }, "test.rb")
      cop = RuboCop::Cop::Sure::SortedList.new(config)
      processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, "test.rb")
      report = RuboCop::Cop::Commissioner.new([ cop ], [], raise_error: true).investigate(processed)
      assert_empty report.errors
      report.offenses
    end
end
