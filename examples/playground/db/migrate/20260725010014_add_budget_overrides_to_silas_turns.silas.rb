# This migration comes from silas (originally 20260716000001)
class AddBudgetOverridesToSilasTurns < ActiveRecord::Migration[8.1]
  def change
    # Per-turn budget raises (max_cost / max_input_tokens / timeout), set by a
    # human topping up a budget-parked turn. Overrides agent.yml/config limits.
    add_column :silas_turns, :budget_overrides, :json, null: false, default: {}
  end
end
