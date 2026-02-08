# spec/models/account_spec.rb
require "rails_helper"

RSpec.describe Account, type: :model do
  describe "accountable subtype persistence" do
    it "updates and reloads property subtype" do
      account = create(
        :account,
        accountable: build(:property, subtype: "Single Family House")
      )

      expect {
        account.update!(
            accountable_attributes: { subtype: "Townhouse" }
        )
      }.to change {
        account.accountable.reload.subtype
      }.from("Single Family House").to("Townhouse")
    end
  end
end


