require "test_helper"

class EnvelopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @envelope = envelopes(:holidays)
    @category = categories(:income)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get envelopes_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "index renders" do
    get envelopes_url
    assert_response :success
    assert_match(/Envelopes/i, response.body)
  end

  test "show renders the envelope" do
    get envelope_url(@envelope)
    assert_response :success
    assert_match(@envelope.name, response.body)
  end

  test "new renders the modal form" do
    get new_envelope_url
    assert_response :success
  end

  test "create persists an envelope" do
    assert_difference -> { Envelope.count } => 1 do
      post envelopes_url, params: {
        envelope: {
          name: "New envelope",
          category_id: @category.id,
          monthly_contribution: "250",
          currency: "USD",
          starts_on: Date.current.beginning_of_month.iso8601,
          color: "#4da568"
        }
      }
    end

    envelope = Envelope.order(created_at: :desc).first
    assert_redirected_to envelope_path(envelope)
    assert_equal 250.to_d, envelope.monthly_contribution
  end

  test "create with a target_amount makes a virtual goal" do
    post envelopes_url, params: {
      envelope: {
        name: "Boiler",
        monthly_contribution: "100",
        currency: "USD",
        starts_on: Date.current.beginning_of_month.iso8601,
        target_amount: "1500",
        color: "#4da568"
      }
    }

    envelope = Envelope.order(created_at: :desc).first
    assert envelope.has_target?
    assert_redirected_to envelope_path(envelope)
  end

  test "create rejects a blank name" do
    assert_no_difference "Envelope.count" do
      post envelopes_url, params: {
        envelope: { name: "", monthly_contribution: "100", currency: "USD", starts_on: Date.current.iso8601 }
      }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the modal form" do
    get edit_envelope_url(@envelope)
    assert_response :success
  end

  test "new form omits categories already backing another envelope" do
    family = @user.family
    cat_taken = Category.create!(name: "Taken WT", family: family, color: "#4da568", lucide_icon: "plane")
    cat_free = Category.create!(name: "Free WT", family: family, color: "#6471eb", lucide_icon: "house")
    family.envelopes.create!(name: "Owner WT", category: cat_taken, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    get new_envelope_url
    assert_response :success
    assert_no_match %r{data-value="#{cat_taken.id}"}, response.body
    assert_match %r{data-value="#{cat_free.id}"}, response.body
  end

  test "new form omits the parent of a category already backing an envelope" do
    family = @user.family
    parent = Category.create!(name: "Holidays WT", family: family, color: "#4da568", lucide_icon: "plane")
    child = Category.create!(name: "Flights WT", parent: parent, family: family)
    family.envelopes.create!(name: "Flights env WT", category: child, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    get new_envelope_url
    assert_response :success
    # Picking the parent would roll the child's spend up into it, so the model
    # rejects the overlap — the form must not offer it (it would 422 on submit).
    assert_no_match %r{data-value="#{parent.id}"}, response.body
    assert_no_match %r{data-value="#{child.id}"}, response.body
  end

  test "new form omits child categories when their parent backs an envelope" do
    family = @user.family
    parent = Category.create!(name: "Bills WT", family: family, color: "#6471eb", lucide_icon: "house")
    child = Category.create!(name: "Electric WT", parent: parent, family: family)
    family.envelopes.create!(name: "Bills env WT", category: parent, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    get new_envelope_url
    assert_response :success
    assert_no_match %r{data-value="#{parent.id}"}, response.body
    assert_no_match %r{data-value="#{child.id}"}, response.body
  end

  test "edit form keeps the envelope's own category assignable" do
    family = @user.family
    cat = Category.create!(name: "Owned WT", family: family, color: "#4da568", lucide_icon: "plane")
    env = family.envelopes.create!(name: "Owner2 WT", category: cat, monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    get edit_envelope_url(env)
    assert_response :success
    assert_match %r{data-value="#{cat.id}"}, response.body
  end

  test "update changes the envelope" do
    patch envelope_url(@envelope), params: {
      envelope: { name: "Renamed", monthly_contribution: "400" }
    }

    assert_redirected_to envelope_path(@envelope)
    assert_equal "Renamed", @envelope.reload.name
    assert_equal 400.to_d, @envelope.monthly_contribution
  end

  test "update rejects an invalid contribution" do
    patch envelope_url(@envelope), params: {
      envelope: { monthly_contribution: "-50" }
    }

    assert_response :unprocessable_entity
  end

  test "destroy deletes the envelope" do
    assert_difference "Envelope.count", -1 do
      delete envelope_url(@envelope)
    end

    assert_redirected_to envelopes_path
  end

  test "scopes envelopes to the current family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = other_family.envelopes.create!(name: "Foreign", monthly_contribution: 10, currency: "USD", starts_on: Date.current.beginning_of_month)

    get envelope_url(foreign)

    assert_redirected_to envelopes_path
  end
end
