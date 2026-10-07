defmodule Genswarms.Config.Loader do
  @moduledoc """
  Configuration loader supporting multiple file formats.

  Supports:
  - `.exs` - Elixir term files
  - `.json` - JSON files
  - `.yaml` / `.yml` - YAML files
  """

  alias Genswarms.Config.SwarmConfig

  @doc """
  Loads and parses a swarm configuration from a file.

  The format is determined by the file extension.
  """
  @spec load(String.t()) :: {:ok, SwarmConfig.t()} | {:error, term()}
  def load(path) do
    Code.ensure_loaded!(SwarmConfig)

    expanded_path = Path.expand(path)

    # Match application startup: tests and embedded callers can disable dotenv.
    if Application.get_env(:genswarms, :load_dotenv, true) do
      Genswarms.CLI.EnvManager.auto_load(Path.dirname(expanded_path))
    end

    with {:ok, _} <- check_file_exists(expanded_path),
         {:ok, config} <- load_file(expanded_path) do
      SwarmConfig.parse(config)
    end
  end

  @doc """
  Loads configuration from a string with explicit format.
  """
  @spec load_string(String.t(), :exs | :json | :yaml) ::
          {:ok, SwarmConfig.t()} | {:error, term()}
  def load_string(content, format) do
    Code.ensure_loaded!(SwarmConfig)

    with {:ok, config} <- parse_string(content, format) do
      SwarmConfig.parse_existing(config)
    end
  end

  @doc "Normalizes a request configuration map without creating atoms."
  def load_map(config) do
    Code.ensure_loaded!(SwarmConfig)

    with {:ok, normalized} <- normalize_config(config, &existing_key/1),
         do: SwarmConfig.parse_existing(normalized)
  end

  # Private functions

  defp check_file_exists(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:file_not_found, path}}
    end
  end

  defp load_file(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".exs" -> load_exs(path)
      ".json" -> load_json(path)
      ".yaml" -> load_yaml(path)
      ".yml" -> load_yaml(path)
      _ -> {:error, {:unsupported_format, ext}}
    end
  end

  defp load_exs(path) do
    try do
      {config, _bindings} = Code.eval_file(path)
      normalize_config(config)
    rescue
      e -> {:error, {:eval_error, e}}
    end
  end

  defp load_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      normalize_config(data)
    end
  end

  defp load_yaml(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- YamlElixir.read_from_string(content) do
      normalize_config(data)
    end
  end

  defp parse_string(_content, :exs) do
    # `.exs` is executable Elixir. The only source of *string* configs is the
    # network API, which is untrusted, so evaluating it would be arbitrary code
    # execution (RCE). String configs must be data-only (json/yaml). Trusted
    # `.exs` *files* are still supported via `load/1` (the local CLI workflow).
    {:error, :exs_string_not_supported}
  end

  defp parse_string(content, :json) do
    with {:ok, data} <- Jason.decode(content) do
      normalize_config(data, &existing_key/1)
    end
  end

  defp parse_string(content, :yaml) do
    with {:ok, data} <- YamlElixir.read_from_string(content) do
      normalize_config(data, &existing_key/1)
    end
  end

  # Local config files are operator-owned; request configs supply existing_key/1.
  defp normalize_config(config, key_fun \\ &String.to_atom/1)

  defp normalize_config(config, key_fun) when is_map(config) do
    config = deep_atomize_keys(config, key_fun)
    # Normalize agent backends from strings to atoms
    config = normalize_agent_backends(config)
    {:ok, config}
  end

  defp normalize_config(config, _key_fun), do: {:ok, config}

  # Convert serialized backend values to runtime forms.
  defp normalize_agent_backends(%{agents: agents} = config) when is_list(agents) do
    normalized_agents = Enum.map(agents, &normalize_agent_backend/1)
    %{config | agents: normalized_agents}
  end

  defp normalize_agent_backends(config), do: config

  defp normalize_agent_backend(%{backend: backend} = agent) when is_binary(backend) do
    normalized =
      case String.split(backend, ":", parts: 2) do
        ["tmux", client] when client in ~w(codex claude opencode) -> {:tmux, client}
        [bare] -> existing_key(bare)
        _ -> backend
      end

    %{agent | backend: normalized}
  end

  defp normalize_agent_backend(%{backend: %{type: "tmux", client: client} = backend} = agent) do
    opts = Map.get(backend, :opts, %{})
    %{agent | backend: {:tmux, client, opts}}
  end

  defp normalize_agent_backend(agent), do: agent

  defp deep_atomize_keys(map, key_fun) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {key_fun.(k), deep_atomize_keys(v, key_fun)}
      {k, v} -> {k, deep_atomize_keys(v, key_fun)}
    end)
  end

  defp deep_atomize_keys(list, key_fun) when is_list(list) do
    Enum.map(list, &deep_atomize_keys(&1, key_fun))
  end

  defp deep_atomize_keys({a, b}, key_fun),
    do: {deep_atomize_keys(a, key_fun), deep_atomize_keys(b, key_fun)}

  defp deep_atomize_keys(value, _key_fun), do: value

  defp existing_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
