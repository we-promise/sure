require "test_helper"

class LegacyWriterGuardTest < ActiveSupport::TestCase
  Fence = Provider::AccountData::LegacyWriterFence

  test "the declared method receives a fresh receiver and preserves arguments block and return value" do
    type = Class.new do
      include LegacyWriterGuard
      attr_accessor :value

      def execute(prefix, options = {}, suffix:, &block)
        block.call([ prefix, options, suffix, value ])
      end

      guard_legacy_writes execute: :ingest
    end
    stale, fresh = type.new, type.new
    stale.value, fresh.value = "old", "fresh"
    returned = Object.new
    Fence.expects(:with_item).with(stale, operation: :ingest).yields(fresh)

    actual = stale.execute("prefix", { hash: "positional" }, suffix: "suffix") do |received|
      assert_equal [ "prefix", { hash: "positional" }, "suffix", "fresh" ], received
      returned
    end

    assert_same returned, actual
    assert_equal "old", stale.value
  end

  test "guard denial does not enter the original method or its rescue and ensure clauses" do
    type = Class.new do
      include LegacyWriterGuard
      attr_reader :entered, :rescued, :ensured

      def execute
        @entered = true
      rescue StandardError
        @rescued = true
      ensure
        @ensured = true
      end

      guard_legacy_writes execute: :publish
    end
    receiver = type.new
    Fence.expects(:with_item).with(receiver, operation: :publish).raises(Fence::OwnershipChanged)

    assert_raises(Fence::OwnershipChanged) { receiver.execute }

    assert_nil receiver.entered
    assert_nil receiver.rescued
    assert_nil receiver.ensured
  end

  test "exceptions from the admitted original keep their identity and run its cleanup" do
    type = Class.new do
      include LegacyWriterGuard
      attr_reader :ensured

      def execute(error:)
        raise error
      ensure
        @ensured = true
      end

      guard_legacy_writes execute: :ingest
    end
    stale, fresh = type.new, type.new
    failure = IOError.new("simulated upstream failure")
    Fence.expects(:with_item).with(stale, operation: :ingest).yields(fresh)

    assert_same failure, assert_raises(IOError) { stale.execute(error: failure) }
    assert fresh.ensured
    assert_nil stale.ensured
  end

  test "repeated declarations do not stack wrappers and cannot change ownership purpose" do
    type = Class.new do
      include LegacyWriterGuard

      def execute
        :result
      end

      guard_legacy_writes execute: :publish
      guard_legacy_writes execute: :publish
    end
    receiver = type.new
    Fence.expects(:with_item).with(receiver, operation: :publish).once.yields(receiver)
    assert_equal :result, receiver.execute
    assert_raises(ArgumentError) { type.class_eval { guard_legacy_writes execute: :ingest } }
  end

  test "declarations reject missing private inherited and unsupported methods before installing any wrapper" do
    base = Class.new do
      def inherited_call; end
    end
    type = Class.new(base) do
      include LegacyWriterGuard
      def existing_call; end

      private
        def private_call; end
    end
    [ { missing_call: :ingest }, { private_call: :publish }, { inherited_call: :publish },
      { existing_call: :credentials }, { existing_call: :ingest, missing_call: :publish } ].each do |declarations|
      assert_raises(ArgumentError) { type.class_eval { guard_legacy_writes(**declarations) } }
      assert_equal type, type.instance_method(:existing_call).owner
    end
    assert_not type.respond_to?(:guard_legacy_writes)
  end

  test "every adopted legacy item rejects direct import and processing before original code runs" do
    adopted = Provider::AccountData::MigrationManifest.all
    assert_equal 23, adopted.size
    adopted.each do |manifest|
      type = manifest.item_type.constantize
      receiver = type.new
      imports = type.public_instance_methods(false).grep(/\Aimport_latest_/)
      assert_equal 1, imports.size, "Expected an explicit import entrypoint on #{type}"
      [ [ imports.sole, :ingest ], [ :process_accounts, :publish ] ].each do |method_name, operation|
        Fence.expects(:with_item).with(receiver, operation: operation).raises(Fence::OwnershipChanged)
        assert_raises(Fence::OwnershipChanged, "#{type}##{method_name} must enter the fence first") do
          receiver.public_send(method_name)
        end
      end
    end
  end
end
