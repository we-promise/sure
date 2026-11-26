class ApplicationMailbox < ActionMailbox::Base
  # The only mailbox is the order mailbox; its sender checks decide what is accepted.
  routing all: :purchases
end
