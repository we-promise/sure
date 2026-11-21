require "test_helper"

class Provider::EnvTuningTest < ActiveSupport::TestCase
  class Probe
    include Provider::EnvTuning

    public :env_positive_integer, :env_interval
  end

  setup do
    @probe = Probe.new
    Provider::EnvTuning::WARNED.clear
  end

  test "env_positive_integer falls back to the default and logs the variable for a value that is not a positive whole number" do
    [ "abc", "0", "-5", "0x10", "1e3", "12abc", "1.5" ].each do |value|
      result, log = read(:env_positive_integer, "PROBE_MAX", value, 25)

      assert_equal 25, result, "for #{value.inspect}"
      assert_equal "PROBE_MAX must be a positive whole number, got #{value.inspect}; using 25\n", log, "for #{value.inspect}"
    end
  end

  test "env_positive_integer reads a whole number in base 10 and treats blank as unset" do
    { "100" => 100, " 42 " => 42, "010" => 10, "" => 25, "  " => 25, nil => 25 }.each do |value, expected|
      result, log = read(:env_positive_integer, "PROBE_MAX", value, 25)

      assert_equal expected, result, "for #{value.inspect}"
      assert_empty log, "for #{value.inspect}"
    end
  end

  test "env_interval falls back to the default and logs the variable for a value that is not a finite number of seconds, 0 or more" do
    [ "abc", "-1", "1e309", "2.5s" ].each do |value|
      result, log = read(:env_interval, "PROBE_INTERVAL", value, 1.0)

      assert_equal 1.0, result, "for #{value.inspect}"
      assert_equal "PROBE_INTERVAL must be a number of seconds, 0 or more, got #{value.inspect}; using 1.0\n", log, "for #{value.inspect}"
    end
  end

  test "env_interval reads zero as no pause, reads a positive number, and treats blank as unset" do
    { "0" => 0.0, "2.5" => 2.5, " 0.25 " => 0.25, "3" => 3.0, "" => 1.0, nil => 1.0 }.each do |value, expected|
      result, log = read(:env_interval, "PROBE_INTERVAL", value, 1.0)

      assert_equal expected, result, "for #{value.inspect}"
      assert_empty log, "for #{value.inspect}"
    end
  end

  test "a bad value is logged once per process, and again when it changes" do
    _, first = read(:env_positive_integer, "PROBE_MAX", "abc", 25)
    _, repeat = read(:env_positive_integer, "PROBE_MAX", "abc", 25)
    _, changed = read(:env_positive_integer, "PROBE_MAX", "xyz", 25)

    assert_match(/PROBE_MAX/, first)
    assert_empty repeat
    assert_match(/"xyz"/, changed)
  end

  private
    def read(method, key, value, default)
      io = StringIO.new
      Rails.stubs(:logger).returns(ActiveSupport::Logger.new(io, formatter: ->(*, message) { "#{message}\n" }))
      result = with_env_overrides(key => value) { @probe.public_send(method, key, default) }
      [ result, io.string ]
    end
end
