class Order < ApplicationRecord
  has_many :refunds, dependent: :destroy
end
