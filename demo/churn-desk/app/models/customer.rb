class Customer < ApplicationRecord
  has_one :subscription, dependent: :destroy
  has_many :charges, dependent: :destroy
  has_many :credits, dependent: :destroy
end
