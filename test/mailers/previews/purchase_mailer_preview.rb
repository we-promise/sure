class PurchaseMailerPreview < ActionMailer::Preview
  def processed = PurchaseMailer.with(purchase: Purchase.first).processed
  def matched = PurchaseMailer.with(purchase: Purchase.matched.first || Purchase.first).matched
  def unmatched = PurchaseMailer.with(purchase: Purchase.first).unmatched
  def needs_matching = PurchaseMailer.with(purchase: Purchase.first).needs_matching
  def rejected = PurchaseMailer.with(purchase: Purchase.first).rejected
  def failed = PurchaseMailer.with(purchase: Purchase.first).failed
  def preview_required = PurchaseMailer.with(user: User.first).preview_required
end
