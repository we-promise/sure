# Run with bundle exec ruby, never rails runner. No application boot or database.
require "active_record"
require "active_support/all"
require "minitest/autorun"
require "minitest/mock"

ActiveRecord::Encryption.configure(
  primary_key: "synthetic-primary-key-not-a-secret",
  deterministic_key: "synthetic-current-key-not-a-secret",
  key_derivation_salt: "synthetic-salt-not-a-secret",
  support_unencrypted_data: true,
  extend_queries: true
)
ActiveRecord::Encryption::ExtendedDeterministicQueries.install_support
ActiveRecord::Encryption::ExtendedDeterministicUniquenessValidator.install_support

# The stdin runner supplies only reviewed source bytes, not application files or ENV.
if defined?(COMPATIBILITY_SOURCE)
  eval(COMPATIBILITY_SOURCE, TOPLEVEL_BINDING, "normalized_encryption_compatibility.rb")
  NormalizedEncryptionCompatibility.install!
elsif ENV["COMPATIBILITY_BASELINE"] != "1"
  require_relative "../../lib/normalized_encryption_compatibility"
  NormalizedEncryptionCompatibility.install!
end

class NormalizedEncryptionCompatibilityTest < Minitest::Test
  Query = ActiveRecord::Encryption::ExtendedDeterministicQueries
  ATTRIBUTES = %w[email unconfirmed_email].freeze
  INPUTS = [ "person@example.test", "PERSON@EXAMPLE.TEST", "  Person@Example.Test  " ].freeze

  def setup
    @encrypted = ActiveRecord::Encryption::EncryptedAttributeType.new(
      scheme: ActiveRecord::Encryption::Scheme.new(
        deterministic: { fixed: false }, support_unencrypted_data: true,
        previous_schemes: [ ActiveRecord::Encryption::Scheme.new(
          deterministic: true, key: "synthetic-retired-key-not-a-secret", support_unencrypted_data: false
        ) ]
      )
    )
    @type = ActiveModel::Attributes::Normalization::NormalizedValueType.new(
      cast_type: @encrypted, normalizer: ->(value) { value&.strip&.downcase }, normalize_nil: false
    )
    type = @type
    @owner = Class.new do
      define_singleton_method(:deterministic_encrypted_attributes) { ATTRIBUTES }
      define_singleton_method(:type_for_attribute) { |_name| type }
    end
  end

  ATTRIBUTES.each do |attribute|
    INPUTS.each_with_index do |input, variant|
      define_method("test_#{attribute}_query_variant_#{variant}") do
        expanded = Query::EncryptedQuery.process_arguments(@owner, [ { attribute => input } ], false).first.fetch(attribute)
        serialized = expanded.map { |value| @type.serialize(value) }
        assert_includes serialized, "person@example.test", "legacy plaintext predicate"
        assert_includes serialized, @encrypted.serialize("person@example.test"), "current ciphertext predicate"
        @encrypted.previous_types.each do |previous|
          assert_includes serialized, previous.serialize("person@example.test"), "previous scheme predicate"
        end
        again = Query::EncryptedQuery.process_arguments(@owner, [ { attribute => expanded } ], true).first.fetch(attribute)
        assert_equal expanded, again, "relation must not expand core query twice"
      end
    end
  end

  def test_marker_passes_through_normalizer_without_casting_ciphertext
    @encrypted.previous_types.each do |previous|
      marker = Query::AdditionalValue.new("person@example.test", previous)
      assert_same marker, @type.cast(marker)
      assert_equal marker.value, @type.serialize(marker)
    end
  end

  def test_roundtrips_and_legacy_reads
    INPUTS.each do |input|
      ciphertext = @type.serialize(input)
      refute_equal "person@example.test", ciphertext
      assert_equal "person@example.test", @type.deserialize(ciphertext)
    end
    assert_equal "person@example.test", @type.deserialize("person@example.test")
    @encrypted.previous_types.each do |previous|
      assert_equal "person@example.test", @type.deserialize(previous.serialize("person@example.test"))
    end
    assert_nil @type.cast(nil)
    assert_equal "", @type.cast("  ")
  end

  # Exercise the actual Rails extension with a synthetic underlying validator.
  # This proves marker/normalization behavior, not DB-backed uniqueness or login.
  def test_uniqueness_extension_preserves_previous_predicates_and_duplicate_errors
    type = @type
    owner = @owner
    owner.class_eval { attr_accessor :errors }
    record = owner.new
    record.errors = ActiveModel::Errors.new(record)
    base = Class.new do
      attr_reader :predicates
      define_method(:validate_each) do |item, attribute, value|
        @predicates ||= []
        serialized = type.serialize(value)
        @predicates << serialized
        item.errors.add(attribute, :taken) if serialized == "person@example.test"
      end
    end
    base.prepend(ActiveRecord::Encryption::ExtendedDeterministicUniquenessValidator::EncryptedUniquenessValidator)
    validator = base.new
    validator.validate_each(record, "email", @type.cast(INPUTS.last))
    assert_includes validator.predicates, "person@example.test"
    assert record.errors.added?("email", :taken)
    @encrypted.previous_types.each do |previous|
      assert_includes validator.predicates, previous.serialize("person@example.test")
    end
  end

  def test_non_encrypted_normalization_is_unchanged
    type = ActiveModel::Attributes::Normalization::NormalizedValueType.new(
      cast_type: ActiveModel::Type::String.new, normalizer: ->(value) { value.strip.downcase }, normalize_nil: false
    )
    assert_equal "name", type.cast(" NAME ")
  end

  def test_array_queries_keep_each_normalized_previous_value
    expanded = Query::EncryptedQuery.process_arguments(@owner,
      [ { "email" => [ " Person@Example.Test ", " Other@Example.Test " ] } ], true).first.fetch("email")
    values = expanded.map { |value| @type.serialize(value) }
    %w[person@example.test other@example.test].each do |value|
      assert_includes values, value
      @encrypted.previous_types.each { |previous| assert_includes values, previous.serialize(value) }
    end
  end

  def test_normalization_occurs_once_on_optimized_save_path
    calls = 0
    type = ActiveModel::Attributes::Normalization::NormalizedValueType.new(
      cast_type: @encrypted, normalizer: ->(value) { calls += 1; value.strip.downcase }, normalize_nil: false
    )
    normalized = type.cast(" Person@Example.Test ")
    ciphertext = type.serialize_cast_value(normalized)
    assert_equal 1, calls
    assert_equal "person@example.test", type.deserialize(ciphertext)
  end

  def test_install_is_idempotent_and_version_scoped
    skip "baseline intentionally has no compatibility installer" unless defined?(NormalizedEncryptionCompatibility)
    ancestors = Query::EncryptedQuery.singleton_class.ancestors.dup
    NormalizedEncryptionCompatibility.install!
    assert_equal ancestors, Query::EncryptedQuery.singleton_class.ancestors
    ActiveRecord.stub(:version, Gem::Version.new("8.2.0")) do
      assert_raises(RuntimeError) { NormalizedEncryptionCompatibility.install! }
    end
  end
end
