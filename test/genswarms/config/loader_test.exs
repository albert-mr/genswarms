defmodule Genswarms.Config.LoaderTest do
  use ExUnit.Case, async: true

  alias Genswarms.Config.Loader

  describe "load_string/2" do
    test "request configs still require an explicit agents list" do
      assert {:error, :missing_or_empty_agents} = Loader.load_map(%{"name" => "request"})
    end

    test "request configs reject unknown names without creating atoms" do
      for format <- [:json, :yaml] do
        name = "config_unknown_#{System.unique_integer([:positive])}"

        content =
          if format == :json,
            do: Jason.encode!(%{name: "request", agents: [%{name: name, backend: "mock"}]}),
            else: "name: request\nagents:\n  - name: #{name}\n    backend: mock\n"

        assert {:error, :unknown_name} = Loader.load_string(content, format)
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end

    test "request config keys and backend types never create atoms" do
      for format <- [:json, :yaml] do
        key = "config_key_unknown_#{System.unique_integer([:positive])}"

        content =
          if format == :json,
            do:
              Jason.encode!(%{
                name: "request",
                agents: [%{name: "agent1", backend: "mock", config: %{key => 1}}]
              }),
            else:
              "name: request\nagents:\n  - name: agent1\n    backend: mock\n    config:\n      #{key}: 1\n"

        assert {:ok, config} = Loader.load_string(content, format)
        assert hd(config.agents).config[key] == 1
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

        backend = "backend_unknown_#{System.unique_integer([:positive])}"
        content = Jason.encode!(%{name: "request", agents: [%{name: "agent1", backend: backend}]})
        assert {:error, _} = Loader.load_string(content, :json)
        assert_raise ArgumentError, fn -> String.to_existing_atom(backend) end
      end
    end

    test "refuses to evaluate .exs string content (RCE hardening)" do
      content = """
      %{
        name: "test-swarm",
        agents: [
          %{name: :agent1, backend: :local}
        ],
        topology: []
      }
      """

      assert {:error, :exs_string_not_supported} = Loader.load_string(content, :exs)
    end

    test "does not execute code embedded in .exs string content (no RCE side effect)" do
      marker = Path.join(System.tmp_dir!(), "loader_rce_#{System.unique_integer([:positive])}")
      File.rm(marker)

      content = ~s|File.write!(#{inspect(marker)}, "pwned"); %{name: "x", agents: []}|

      assert {:error, :exs_string_not_supported} = Loader.load_string(content, :exs)
      refute File.exists?(marker), "RCE: embedded code in .exs string content was executed"
    end

    test "loads configuration from JSON string" do
      content = """
      {
        "name": "test-swarm",
        "agents": [
          {"name": "agent1", "backend": "local"}
        ],
        "topology": []
      }
      """

      {:ok, config} = Loader.load_string(content, :json)

      assert config.name == "test-swarm"
      assert hd(config.agents).name == :agent1
    end

    test "loads Apple container scalar backend from JSON string" do
      content = """
      {
        "name": "test-swarm",
        "agents": [
          {"name": "agent1", "backend": "apple_container"}
        ],
        "topology": []
      }
      """

      {:ok, config} = Loader.load_string(content, :json)

      assert [%{backend: :apple_container}] = config.agents
    end

    test "loads a tmux client and options from JSON data" do
      content = """
      {
        "name": "test-swarm",
        "agents": [
          {
            "name": "agent1",
            "backend": {
              "type": "tmux",
              "client": "codex",
              "opts": {
                "workspace": "/tmp/project",
                "resume": true,
                "runner": "docker",
                "image": "coding-tuis:latest",
                "client_source": "runtime",
                "network": "none"
              }
            }
          }
        ],
        "topology": []
      }
      """

      assert {:ok, config} = Loader.load_string(content, :json)

      assert [
               %{
                 backend:
                   {:tmux, "codex",
                    %{
                      workspace: "/tmp/project",
                      resume: true,
                      runner: "docker",
                      image: "coding-tuis:latest",
                      client_source: "runtime",
                      network: "none"
                    }}
               }
             ] = config.agents
    end

    test "loads configuration from YAML string" do
      content = """
      name: test-swarm
      agents:
        - name: agent1
          backend: local
      topology: []
      """

      {:ok, config} = Loader.load_string(content, :yaml)

      assert config.name == "test-swarm"
    end

    test "returns error for invalid JSON" do
      content = "not valid json"
      assert {:error, _} = Loader.load_string(content, :json)
    end
  end

  describe "load/1" do
    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = Loader.load("/nonexistent/path.exs")
    end
  end
end
