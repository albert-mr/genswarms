defmodule GenswarmsWeb.UntrustedNamesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  alias GenswarmsWeb.{SwarmController, EventsController, SwarmChannel}

  defmodule Handler do
    @behaviour Genswarms.Objects.ObjectHandler
    def init(_), do: {:ok, %{}}
    def handle_message(_, _, state), do: {:noreply, state}
    def interface(), do: %{}
  end

  defp fresh, do: "http_unknown_#{System.unique_integer([:positive])}"
  defp uninterned(name), do: assert_raise(ArgumentError, fn -> String.to_existing_atom(name) end)

  test "unknown agent lookups return errors without creating atoms" do
    for action <- [:show_agent, :agent_logs, :agent_history, :agent_skills, :update_skill] do
      name = fresh()

      params = %{
        "swarm_name" => "missing",
        "agent_name" => name,
        "skill_name" => "x.md",
        "content" => "x"
      }

      conn = apply(SwarmController, action, [build_conn(), params])
      assert conn.status == 404
      uninterned(name)
    end
  end

  test "HTTP routing and topology do not create destination atoms" do
    name = fresh()

    conn =
      SwarmController.route_message(build_conn(), %{
        "name" => "missing",
        "from" => "alpha",
        "to" => name,
        "content" => "x"
      })

    assert conn.status == 400
    uninterned(name)
    name = fresh()

    conn =
      SwarmController.patch_topology(build_conn(), %{
        "swarm_name" => "missing",
        "add" => [["alpha", name]]
      })

    assert conn.status == 400
    uninterned(name)
  end

  test "HTTP agent and object creation reject names that have not been configured" do
    for {action, extra} <- [
          {:add_agent, %{"backend" => "mock"}},
          {:add_object, %{"handler" => inspect(Handler)}}
        ] do
      name = fresh()
      params = Map.merge(%{"swarm_name" => "missing", "name" => name}, extra)
      conn = apply(SwarmController, action, [build_conn(), params])
      assert conn.status == 400
      uninterned(name)
    end
  end

  test "HTTP config creation rejects fresh names before boot" do
    name = fresh()

    conn =
      SwarmController.create(build_conn(), %{
        "config" => %{name: "http-new", agents: [%{name: name, backend: :mock}]}
      })

    assert conn.status == 400
    uninterned(name)

    {:ok, state} =
      Genswarms.IR.FromConfig.from_config(%{
        name: "http-ir-new",
        agents: [%{name: name, backend: :mock}]
      })

    conn = SwarmController.create(build_conn(), %{"ir" => Genswarms.IR.State.to_map(state)})
    assert conn.status == 400
    uninterned(name)
  end

  test "HTTP scaling cannot introduce new derived names" do
    base = fresh()
    swarm = "http-scale-#{System.unique_integer([:positive])}"

    {:ok, ^swarm} =
      Genswarms.SwarmManager.start_from_config(%{
        name: swarm,
        agents: [%{name: base, backend: :mock}]
      })

    on_exit(fn -> Genswarms.SwarmManager.stop(swarm) end)

    conn =
      SwarmController.scale_agent_group(build_conn(), %{
        "swarm_name" => swarm,
        "base_name" => base,
        "count" => 1
      })

    assert conn.status == 400
    uninterned(base <> "_1")
  end

  test "HTTP creation, topology and scaling still work with existing names" do
    swarm = "http-existing-#{System.unique_integer([:positive])}"
    on_exit(fn -> Genswarms.SwarmManager.stop(swarm) end)

    conn =
      SwarmController.create(build_conn(), %{
        "config" => %{
          "name" => swarm,
          "agents" => [%{"name" => Atom.to_string(:http_allowed), "backend" => "mock"}]
        }
      })

    assert conn.status == 201

    conn =
      SwarmController.add_agent(build_conn(), %{
        "swarm_name" => swarm,
        "name" => Atom.to_string(:http_extra),
        "backend" => "mock"
      })

    assert conn.status == 201

    conn =
      SwarmController.add_object(build_conn(), %{
        "swarm_name" => swarm,
        "name" => Atom.to_string(:http_sink),
        "handler" => inspect(Handler)
      })

    assert conn.status == 201

    conn =
      SwarmController.patch_topology(build_conn(), %{
        "swarm_name" => swarm,
        "add" => [["http_allowed", "http_sink"]]
      })

    assert conn.status == 200

    conn =
      SwarmController.scale_agent_group(build_conn(), %{
        "swarm_name" => swarm,
        "base_name" => "http_allowed",
        "count" => 1
      })

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["result"]["added"] == [Atom.to_string(:http_allowed_1)]
  end

  test "HTTP event filters remain strings and do not create atoms" do
    name = fresh()

    conn =
      EventsController.index(build_conn(), %{
        "agent" => name,
        "level" => name,
        "category" => name,
        "event_type" => name
      })

    body = Jason.decode!(conn.resp_body)
    assert body["events"] == []
    uninterned(name)
  end

  test "WebSocket log and event filters do not create atoms" do
    name = fresh()

    socket = %Phoenix.Socket{
      assigns: %{
        swarm_name: "missing",
        log_subscriptions: MapSet.new(),
        event_subscriptions: MapSet.new()
      }
    }

    assert {:reply, {:ok, %{recent_logs: []}}, socket} =
             SwarmChannel.handle_in("subscribe_logs", %{"agent" => name}, socket)

    assert {:reply, {:ok, %{recent_events: []}}, socket} =
             SwarmChannel.handle_in(
               "subscribe_events",
               %{"filters" => %{"level" => name, "category" => name, "event_type" => name}},
               socket
             )

    event = %{agent: :alpha, level: :info, category: :agent, event_type: :stdout}
    assert {:noreply, ^socket} = SwarmChannel.handle_info({:log_event, event}, socket)
    uninterned(name)
  end
end
