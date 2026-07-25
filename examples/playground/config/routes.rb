Rails.application.routes.draw do
  # The operator surface: session list, live trace, approval cards, cost.
  # Deny-by-default — see config/initializers/silas.rb for who gets in.
  mount Silas::Engine => "/silas"

  # The customer surface: one chat page, one Silas session per browser session.
  get  "chat"  => "chats#show",    as: :chat
  post "chat"  => "chats#create"
  delete "chat" => "chats#destroy", as: :reset_chat

  get "up" => "rails/health#show", as: :rails_health_check

  root "chats#show"
end
