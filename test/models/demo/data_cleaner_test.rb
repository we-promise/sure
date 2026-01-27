require "test_helper"

class Demo::DataCleanerTest < ActiveSupport::TestCase
  def setup
    @base_family_attrs = {
      currency: "USD",
      locale: "en",
      country: "US",
      timezone: "America/New_York",
      date_format: "%m-%d-%Y"
    }
  end

  test "destroy_demo_data! removes only demo-marked families" do
    demo_family = Family.create!(@base_family_attrs.merge(name: "Demo Family"))
    demo_family.users.create!(
      email: "demo_user@example.com",
      first_name: "Demo",
      last_name: "User",
      role: "admin",
      password: "Password1!",
      preferences: { Demo::DataCleaner::DEMO_GENERATED_KEY => true, "demo_run_id" => "run-1" }
    )

    regular_family = Family.create!(@base_family_attrs.merge(name: "Regular Family"))
    regular_family.users.create!(
      email: "regular_user@example.com",
      first_name: "Regular",
      last_name: "User",
      role: "admin",
      password: "Password1!"
    )

    Demo::DataCleaner.new.destroy_demo_data!

    assert_not Family.exists?(demo_family.id)
    assert Family.exists?(regular_family.id)
  end
end
