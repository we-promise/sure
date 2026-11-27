require "test_helper"

class DatabaseConfigTest < ActiveSupport::TestCase
  test "app connections run with Postgres JIT off" do
    assert_equal "off", ActiveRecord::Base.connection.select_value("SHOW jit")
  end
end
