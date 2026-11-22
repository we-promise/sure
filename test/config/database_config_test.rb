require "test_helper"

class DatabaseConfigTest < ActiveSupport::TestCase
  test "app connections disable Postgres JIT" do
    assert_equal "off", ActiveRecord::Base.connection.select_value("SHOW jit")
  end
end
