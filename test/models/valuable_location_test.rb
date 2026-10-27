require "test_helper"

class ValuableLocationTest < ActiveSupport::TestCase
  setup do
    @family = accounts(:investment).family
    @account = @family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    @safe = @family.valuable_locations.create!(name: "Home safe")
    @vault = @family.valuable_locations.create!(name: "Bank vault")
    @bar = @account.valuable.lots.create!(description: "Bar", acquired_on: Date.current - 10.days, weight: 100, weight_unit: "gram", karat: 24, cost_amount: 10_000, location: @safe)
    @bar.skip_queued_valuation_refresh = true
  end

  test "names are squished and unique per family regardless of case" do
    assert_equal "Office drawer", @family.valuable_locations.create!(name: "  Office   drawer ").name
    assert_not @family.valuable_locations.build(name: "home SAFE").valid?
    assert families(:empty).valuable_locations.build(name: "Home safe").valid?
  end

  test "an item cannot use another family's location" do
    @bar.location = families(:empty).valuable_locations.create!(name: "Elsewhere")

    assert_not @bar.valid?
    assert_includes @bar.errors.details[:location], { error: :must_belong_to_account_family }
  end

  test "changing an item's location records a move dated today" do
    @bar.update!(location: @vault)

    move = @bar.moves.sole
    assert_equal [ @safe, @vault, Date.current ], [ move.from_location, move.to_location, move.moved_on ]
  end

  test "a move can be backdated within ownership" do
    @bar.update!(location: @vault, moved_on: Date.current - 3.days)
    assert_equal Date.current - 3.days, @bar.moves.sole.moved_on

    assert_not @bar.update(location: @safe, moved_on: @bar.acquired_on - 1.day)
    assert_not @bar.update(location: @safe, moved_on: Date.current + 1.day)
  end

  test "setting a location at creation and other edits record no move" do
    @bar.update!(notes: "Sealed")

    assert_empty @bar.moves
  end

  test "deleting a location clears it from items and keeps their moves" do
    @bar.update!(location: @vault)
    @vault.destroy!

    assert_nil @bar.reload.location
    move = @bar.moves.sole
    assert_equal @safe, move.from_location
    assert_nil move.to_location
  end

  test "deleting an item deletes its moves" do
    @bar.update!(location: @vault)

    assert_difference -> { ValuableItemMove.count }, -1 do
      @bar.destroy!
    end
  end
end
