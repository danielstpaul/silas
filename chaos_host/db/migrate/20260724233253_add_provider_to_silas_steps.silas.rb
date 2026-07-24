# This migration comes from silas (originally 20260725000001)
class AddProviderToSilasSteps < ActiveRecord::Migration[8.1]
  def change
    # The provider RubyLLM's resolution picked for the step's model, stamped at
    # persist time — cost lookups price against (model, provider) forever
    # after, immune to registry tie-break changes (85/1081 registry ids exist
    # under multiple providers at different prices).
    add_column :silas_steps, :provider, :string

    # Declared in 0.1.0, defaulted to 0, never written — a silent lie to
    # anyone who queried it. Cost is derived at read time from step tokens.
    remove_column :silas_turns, :cost_microcents, :integer, null: false, default: 0
  end
end
