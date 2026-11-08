defmodule ArenaWeb.LoadtestControllerTest do
  use ExUnit.Case, async: true
  import Plug.Test

  test "measurement endpoint reports VM and match memory only on loopback" do
    local = %{conn(:get, "/loadtest/measurements") | remote_ip: {127, 0, 0, 1}}
    response = ArenaWeb.Endpoint.call(local, [])
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["build_env"] == "test"
    assert is_integer(body["vm_memory_bytes"])
    assert is_integer(body["match_process_memory_bytes"])
    assert is_integer(body["match_process_count"])
    assert is_binary(body["os_pid"])

    remote = %{conn(:get, "/loadtest/measurements") | remote_ip: {192, 0, 2, 10}}
    assert ArenaWeb.Endpoint.call(remote, []).status == 403
  end
end
