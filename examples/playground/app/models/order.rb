class Order < ApplicationRecord
  belongs_to :customer
  has_many :refunds, dependent: :destroy

  def refunded_pence = refunds.sum(:amount_pence)
  def refundable_pence = amount_pence - refunded_pence
end
