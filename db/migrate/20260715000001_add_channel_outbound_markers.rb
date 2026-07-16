class AddChannelOutboundMarkers < ActiveRecord::Migration[8.1]
  def change
    # Outbound delivery idempotency keys (CAS-claimed by ChannelDeliveryJob):
    # an approval is pinged once, a turn's answer is delivered once.
    add_column :silas_tool_invocations, :notified_at, :datetime
    add_column :silas_turns, :answered_at, :datetime
  end
end
