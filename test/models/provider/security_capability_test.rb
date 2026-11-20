require "test_helper"

# `supplies_classification?` and `supplies_constituents?` gate whether a
# provider is asked at all, so a provider that CAN answer and forgets to say so
# is silently never asked -- classification simply stops, a fund's holdings are
# never stored, and both read as missing data rather than as a missing line of
# code.
#
# So the declarations are checked against what the providers actually build. The
# source is read rather than the provider called, because calling means API keys
# and network, and the thing worth pinning is the pairing itself.
class Provider::SecurityCapabilityTest < ActiveSupport::TestCase
  PROVIDER_FILES = Dir[Rails.root.join("app/models/provider/*.rb")].freeze

  # Either field is a classification: a provider that returns only an industry
  # still has to be asked.
  # A keyword at the start of a line or after `(` or `,`, so a provider that
  # passes it on the same line as `SecurityInfo.new(` is still seen.
  BUILDS_CLASSIFICATION = /(?:^|[(,])\s*(sector|industry):/
  BUILDS_CONSTITUENTS = /(?:^|[(,])\s*constituents:/

  # Read the sector from a metadata answer, but are never asked for one alone:
  # Alpha Vantage's OVERVIEW is a premium function, so asking on a free key
  # fails, is never stamped, and spends the shared daily allowance on every sync.
  CLASSIFY_ONLY_WITH_METADATA = %w[Provider::AlphaVantage].freeze

  test "every provider that returns a classification declares it" do
    mismatched = capability_mismatches(builds: BUILDS_CLASSIFICATION, declares: :supplies_classification?) -
      CLASSIFY_ONLY_WITH_METADATA

    assert_empty mismatched,
                 "these providers return sector/industry but answer false to supplies_classification?, " \
                 "so the classification gate will never ask them: #{mismatched.join(", ")}"
  end

  # The other direction, so the test above cannot be satisfied by declaring
  # everything true: a provider that builds no classification must not claim one.
  test "a provider that returns no classification does not claim one" do
    overclaiming = security_providers.reject do |klass, source|
      next true if source.match?(BUILDS_CLASSIFICATION)

      !klass.allocate.supplies_classification?
    end.map { |klass, _| klass.name }

    assert_empty overclaiming,
                 "these providers declare a classification they never build: #{overclaiming.join(", ")}"
  end

  test "every provider that returns constituents declares it" do
    mismatched = capability_mismatches(builds: BUILDS_CONSTITUENTS, declares: :supplies_constituents?)

    assert_empty mismatched,
                 "these providers return constituents but answer false to supplies_constituents?, " \
                 "so the constituents gate will never ask them: #{mismatched.join(", ")}"
  end

  # The other direction for constituents. A provider claiming them without
  # building them would be asked once per security and stamp an empty table.
  test "a provider that returns no constituents does not claim them" do
    overclaiming = security_providers.reject do |klass, source|
      next true if source.match?(BUILDS_CONSTITUENTS)

      !klass.allocate.supplies_constituents?
    end.map { |klass, _| klass.name }

    assert_empty overclaiming,
                 "these providers declare constituents they never build: #{overclaiming.join(", ")}"
  end

  # The source check above can only see what the regex matches, so the one
  # provider that returns holdings is also checked through its answer.
  test "a provider whose answer carries holdings declares that it supplies them" do
    provider = Provider::Eodhd.new("test_api_key")
    provider.stubs(:enforce_daily_limit!)
    provider.stubs(:throttle_request)
    body = { "General" => { "Type" => "ETF" },
             "ETF_Data" => { "Holdings" => { "MSFT.US" => { "Code" => "MSFT", "Assets_%" => "5" } } } }
    provider.stubs(:client).returns(client = mock)
    client.stubs(:get).returns(stub(body: body.to_json))

    response = provider.fetch_security_info(symbol: "VT", exchange_operating_mic: "ARCX")

    assert response.success?
    assert_equal [ "MSFT" ], response.data.constituents.map { |entry| entry[:ticker] }
    assert provider.supplies_constituents?
  end

  test "a provider whose classification costs a premium request is not asked for one" do
    CLASSIFY_ONLY_WITH_METADATA.each do |name|
      assert_not name.constantize.allocate.supplies_classification?,
                 "#{name} would be asked for a classification on every sync"
    end
  end

  private
    def security_providers
      PROVIDER_FILES.filter_map do |path|
        klass = "Provider::#{File.basename(path, ".rb").camelize}".safe_constantize
        next unless klass.is_a?(Class) && klass.include?(Provider::SecurityConcept)

        [ klass, File.read(path) ]
      end
    end

    def capability_mismatches(builds:, declares:)
      security_providers.filter_map do |klass, source|
        next unless source.match?(builds)

        klass.name unless klass.allocate.public_send(declares)
      end
    end
end
