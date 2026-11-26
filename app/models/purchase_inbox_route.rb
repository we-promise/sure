# Tells the order mailbox whose an incoming email is: a `sender` route matches the address a user
# forwards from by hand, a `tag` route matches the plus tag of the mailbox address a user's mail
# filter forwards shop emails to.
class PurchaseInboxRoute < ApplicationRecord
  TAG_FORMAT = /\A[a-z0-9][a-z0-9._-]{0,31}\z/

  belongs_to :user

  enum :kind, { sender: "sender", tag: "tag" }, validate: true

  normalizes :value, with: ->(value) { value.to_s.strip.downcase }

  validates :value, presence: true
  validates :value, uniqueness: { scope: :kind, case_sensitive: false }
  validates :value, format: { with: URI::MailTo::EMAIL_REGEXP }, if: :sender?
  validates :value, format: { with: TAG_FORMAT }, if: :tag?
end
