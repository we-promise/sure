require "test_helper"

class FamilyPlanSettingsTest < ActiveSupport::TestCase
  test "defaults to income_ratio attribution" do
    family = users(:family_admin).family
    settings = FamilyPlanSettings.for_family(family)
    assert_equal "income_ratio", settings.leftover_distribution
    assert_nil settings.custom_rules
  end

  test "for_family returns the persisted settings or a blank one" do
    family = users(:family_admin).family
    settings = FamilyPlanSettings.for_family(family)
    assert_equal family.id, settings.family_id
    assert_not settings.persisted?

    settings.leftover_distribution = "equal_split"
    assert settings.save!
    assert FamilyPlanSettings.for_family(family).persisted?
    assert_equal "equal_split", FamilyPlanSettings.for_family(family).leftover_distribution
  end

  test "one settings row per family" do
    family = users(:family_admin).family
    settings = FamilyPlanSettings.for_family(family)
    settings.save!
    assert_equal 1, FamilyPlanSettings.where(family_id: family.id).count
    assert_equal settings.id, FamilyPlanSettings.for_family(family).id
  end
end
