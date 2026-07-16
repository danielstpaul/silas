class AddCancelRequestedToSilasTurns < ActiveRecord::Migration[8.1]
  def change
    # Set by Turn#cancel! on a running turn; the loop honors it at the next
    # step boundary (the same safe point budgets are checked at).
    add_column :silas_turns, :cancel_requested_at, :datetime
  end
end
