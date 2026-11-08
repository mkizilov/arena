defmodule ArenaWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Arena</title>
        <style>
          body { background: #0b1120; color: #e2e8f0; font: 16px system-ui, sans-serif; margin: 0; }
          main { max-width: 960px; margin: auto; padding: 2rem 1rem; }
          a { color: #7dd3fc; } button, input { font: inherit; padding: .55rem .8rem; margin: .3rem; }
          button { cursor: pointer; } button:disabled { cursor: not-allowed; opacity: .5; }
          section { margin-top: 2rem; } canvas { max-width: 100%; height: auto; border: 1px solid #475569; }
        </style>
        <script type="module" src="/assets/game/app.mjs"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
