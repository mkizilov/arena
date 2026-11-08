defmodule ArenaWeb.PageControllerTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Plug.Test

  test "GET / identifies the application" do
    conn = conn(:get, "/") |> ArenaWeb.Endpoint.call([])
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"application" => "arena"}
  end
end
