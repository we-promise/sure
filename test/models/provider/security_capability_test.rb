require "test_helper"

# `supplies_classification?` gates whether a provider is asked at all, so a
# provider that CAN answer and forgets to say so is silently never asked --
# classification simply stops, and reads as missing data rather than as a
# missing line of code.
#
# So the declarations are checked against what the providers actually build. The
# source is read rather than the provider called, because calling means API keys
# and network, and the thing worth pinning is the pairing itself.
class Provider::SecurityCapabilityTest < ActiveSupport::TestCase
  PROVIDER_FILES = Dir[Rails.root.join("app/models/provider/*.rb")].freeze

  test "every provider that returns a classification declares it" do
    mismatched = capability_mismatches(builds: /^\s*sector:/, declares: :supplies_classification?)

    assert_empty mismatched,
                 "these providers return sector/industry but answer false to supplies_classification?, " \
                 "so the classification gate will never ask them: #{mismatched.join(", ")}"
  end

  # The other direction, so the test above cannot be satisfied by declaring
  # everything true: a provider that builds no classification must not claim one.
  test "a provider that returns no classification does not claim one" do
    overclaiming = security_providers.reject do |klass, source|
      next true if source.match?(/^\s*sector:/)

      !klass.allocate.supplies_classification?
    end.map { |klass, _| klass.name }

    assert_empty overclaiming,
                 "these providers declare a classification they never build: #{overclaiming.join(", ")}"
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
