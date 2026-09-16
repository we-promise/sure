# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::ChainDetectorTest < ActiveSupport::TestCase
  include OnchainTestHelper

  ADDRESS = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  # Only #key is read off a candidate here, and only #has_activity? off its
  # adapter, so the detector is exercised without standing up chains.
  Candidate = Struct.new(:key)

  Probe = Struct.new(:answer, :delay) do
    def has_activity?(_address)
      sleep(delay) if delay
      answer
    end
  end

  setup do
    register_fake_chain!
    @item = create_onchain_wallet_item(family: families(:dylan_family))
  end

  teardown do
    unregister_fake_chain!
  end

  test "one chain answering yes settles it when every other chain answered no" do
    result = detect("alpha" => true, "beta" => false)

    assert result.resolved?
    assert_equal "alpha", result.chain
    assert_equal [ "alpha" ], result.detected_keys
  end

  test "a chain that could not answer sends the user to the chooser" do
    result = detect("alpha" => true, "beta" => nil)

    # The single yes is not enough: a source that timed out has not said the
    # address is absent there, and settling on alpha would link the wrong
    # network with no way back.
    assert_not result.resolved?
    assert result.ambiguous?
    assert_equal [ "alpha" ], result.detected_keys
  end

  test "a probe that outlives the deadline counts as could not tell" do
    Onchain::DetectionBudget.stubs(:deadline).returns(0.2)

    result = detect({ "alpha" => true, "beta" => [ true, 5 ] })

    assert result.ambiguous?, "a probe still running at the deadline must not be read as an answer"
    assert_equal [ "alpha" ], result.detected_keys
  end

  test "candidates are probed concurrently rather than one after another" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    detect({ "alpha" => [ false, 0.3 ], "beta" => [ false, 0.3 ], "gamma" => [ false, 0.3 ] })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # In sequence this is 0.9s, and the form waits on it: a 0x address is a
    # candidate on six chains.
    assert_operator elapsed, :<, 0.6, "three 0.3s probes took #{elapsed.round(2)}s, so they ran in sequence"
  end

  private
    def detect(answers)
      pairs = answers.map do |key, answer|
        value, delay = answer.is_a?(Array) ? answer : [ answer, nil ]
        [ Candidate.new(key), Probe.new(value, delay) ]
      end

      @item.stubs(:matching_chain_adapters).returns(pairs)

      OnchainWalletItem::ChainDetector.new(@item, ADDRESS).detect
    end
end
