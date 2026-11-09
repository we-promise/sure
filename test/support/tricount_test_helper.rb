# frozen_string_literal: true

# A made-up tricount in the shape Tricount's API returns: three members and an
# entry of each kind. For "me" it adds up to -20 (owing the group 20):
#   dinner      paid 100, my share 25    +75
#   taxi        Sam paid 40, my share 10 -10
#   settle-up   Sam paid me 65           -65
#   group refund I received 30, share 10 -20
#   deleted     ignored
module TricountTestHelper
  ME = "11111111-1111-1111-1111-111111111111"
  SAM = "22222222-2222-2222-2222-222222222222"
  KIM = "33333333-3333-3333-3333-333333333333"
  REGISTRY_UUID = "99999999-9999-9999-9999-999999999999"
  SHARING_TOKEN = "tTestToken123"

  def tricount_member(uuid, name)
    { "RegistryMembershipNonUser" => { "id" => uuid.hash.abs, "uuid" => uuid, "status" => "ACTIVE", "alias" => { "display_name" => name } } }
  end

  def tricount_entry(uuid:, payer:, amount:, allocations:, date: "2026-10-01 19:30:00.000000", description: "Expense", category: nil, type: "NORMAL", status: "ACTIVE")
    {
      "RegistryEntry" => {
        "id" => uuid.hash.abs,
        "uuid" => uuid,
        "date" => date,
        "description" => description,
        "category" => category,
        "type_transaction" => type,
        "status" => status,
        "amount" => { "value" => amount.to_s, "currency" => "EUR" },
        "amount_local" => { "value" => amount.to_s, "currency" => "EUR" },
        "membership_owned" => { "RegistryMembershipNonUser" => { "uuid" => payer } },
        "allocations" => allocations.map do |member, value|
          { "membership" => { "RegistryMembershipNonUser" => { "uuid" => member } }, "amount" => { "value" => value.to_s, "currency" => "EUR" }, "type" => "AMOUNT" }
        end
      }
    }
  end

  def tricount_entries
    [
      tricount_entry(uuid: "e1", payer: ME, amount: "-100.00", allocations: { ME => "-25.00", SAM => "-25.00", KIM => "-50.00" }, description: "Dinner", category: "FOOD"),
      tricount_entry(uuid: "e2", payer: SAM, amount: "-40.00", allocations: { ME => "-10.00", SAM => "-30.00" }, description: "Taxi", category: "TRANSPORT", date: "2026-10-02 08:00:00.000000"),
      tricount_entry(uuid: "e3", payer: SAM, amount: "-65.00", allocations: { ME => "-65.00" }, description: "Settle up", type: "BALANCE", date: "2026-10-05 12:00:00.000000"),
      tricount_entry(uuid: "e4", payer: ME, amount: "-500.00", allocations: { ME => "-500.00" }, description: "Deleted", status: "DELETED"),
      tricount_entry(uuid: "e5", payer: ME, amount: "30.00", allocations: { ME => "10.00", SAM => "10.00", KIM => "10.00" }, description: "Group refund", type: "INCOME", date: "2026-10-06 09:00:00.000000")
    ]
  end

  def tricount_registry(entries: tricount_entries, title: "Weekend trip")
    {
      "id" => 102257091,
      "uuid" => REGISTRY_UUID,
      "title" => title,
      "currency" => "EUR",
      "status" => "READ_WRITE",
      "public_identifier_token" => SHARING_TOKEN,
      "memberships" => [ tricount_member(ME, "Alex"), tricount_member(SAM, "Sam"), tricount_member(KIM, "Kim") ],
      "all_registry_entry" => entries
    }
  end
end
