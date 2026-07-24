# This migration comes from silas (originally 20260715000002)
class AddAgentSdkColumnsToTurns < ActiveRecord::Migration[8.1]
  def change
    # The Claude Code CLI session id (captured from the system:init event) — the
    # in-doubt marker for fail-closed resume, and the future --resume key.
    add_column :silas_turns, :cli_session_id, :string
    # Per-turn bearer token for the in-worker MCP endpoint.
    add_column :silas_turns, :mcp_token, :string
  end
end
