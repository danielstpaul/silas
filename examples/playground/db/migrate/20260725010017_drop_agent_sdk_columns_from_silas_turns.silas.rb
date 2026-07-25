# This migration comes from silas (originally 20260724000001)
class DropAgentSdkColumnsFromSilasTurns < ActiveRecord::Migration[8.1]
  # The :agent_sdk engine was removed in 0.2. cli_session_id was its fail-closed
  # resume marker; mcp_token was written by Mcp::Server but read by nothing (the
  # token is minted and compared in memory).
  def change
    remove_column :silas_turns, :cli_session_id, :string
    remove_column :silas_turns, :mcp_token, :string
  end
end
