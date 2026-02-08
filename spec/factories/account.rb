FactoryBot.define do
  factory :account do
    name     { "Main account" }
    balance  { 1805 }
    currency { "EUR" }

    association :family
    association :accountable, factory: :property
  end
end
