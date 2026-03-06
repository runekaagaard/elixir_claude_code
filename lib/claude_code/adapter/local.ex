defmodule ClaudeCode.Adapter.Local do
  @moduledoc """
  Local CLI adapter that manages a persistent Port connection to the Claude CLI.

  This adapter:
  - Spawns the CLI subprocess with `--input-format stream-json`
  - Receives async messages from the Port
  - Parses JSON and forwards structured messages to Session
  - Handles Port lifecycle (connect, reconnect, cleanup)
  """

  @behaviour ClaudeCode.Adapter

  use GenServer

  alias ClaudeCode.Adapter
  alias ClaudeCode.Adapter.Local.Installer
  alias ClaudeCode.Adapter.Local.Resolver
  alias ClaudeCode.CLI.Command
  alias ClaudeCode.CLI.Control
  alias ClaudeCode.CLI.Input
  alias ClaudeCode.CLI.Parser
  alias ClaudeCode.Hook
  alias ClaudeCode.Hook.Registry, as: HookRegistry
  alias ClaudeCode.Hook.Response, as: HookResponse
  alias ClaudeCode.MCP.Router, as: MCPRouter
  alias ClaudeCode.MCP.Server, as: MCPServer
  alias ClaudeCode.Message.ResultMessage

  require Logger

  @shell_special_chars ["'", " ", "\"", "$", "`", "\\", "\n", ";", "&", "|", "(", ")"]
  @control_timeout 30_000

  defstruct [
    :session,
    :session_options,
    :os_pid,
    :buffer,
    :current_request,
    :api_key,
    :server_info,
    :hook_registry,
    status: :provisioning,
    control_counter: 0,
    pending_control_requests: %{},
    max_buffer_size: 1_048_576,
    sdk_mcp_servers: %{},
    stderr_lines: []
  ]

  # ============================================================================
  # Client API (Adapter Behaviour)
  # ============================================================================

  @impl ClaudeCode.Adapter
  def start_link(session, opts) do
    GenServer.start_link(__MODULE__, {session, opts})
  end

  @impl ClaudeCode.Adapter
  def send_query(adapter, request_id, prompt, opts) do
    GenServer.call(adapter, {:query, request_id, prompt, opts}, :infinity)
  end

  @impl ClaudeCode.Adapter
  def health(adapter) do
    GenServer.call(adapter, :health)
  end

  @impl ClaudeCode.Adapter
  def stop(adapter) do
    GenServer.stop(adapter, :normal)
  end

  @impl ClaudeCode.Adapter
  def send_control_request(adapter, subtype, params) do
    GenServer.call(adapter, {:control_request, subtype, params}, @control_timeout + 5_000)
  end

  @impl ClaudeCode.Adapter
  def get_server_info(adapter) do
    GenServer.call(adapter, :get_server_info)
  end

  @impl ClaudeCode.Adapter
  def interrupt(adapter) do
    GenServer.call(adapter, :interrupt)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl GenServer
  def init({session, opts}) do
    hooks_map = Keyword.get(opts, :hooks)
    can_use_tool = Keyword.get(opts, :can_use_tool)
    {hook_registry, _wire} = HookRegistry.new(hooks_map, can_use_tool)

    state = %__MODULE__{
      session: session,
      session_options: opts,
      buffer: "",
      api_key: Keyword.get(opts, :api_key),
      max_buffer_size: Keyword.get(opts, :max_buffer_size, 1_048_576),
      hook_registry: hook_registry,
      sdk_mcp_servers: extract_sdk_mcp_servers(opts)
    }

    Process.link(session)
    Adapter.notify_status(session, :provisioning)

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    # Resolve the CLI binary in a separate process so the GenServer stays
    # responsive during potentially slow auto-install (curl | bash).
    # Port opening must happen back in our process for ownership.
    adapter = self()
    session_options = state.session_options
    api_key = state.api_key

    Task.start_link(fn ->
      result = resolve_cli(session_options, api_key)
      send(adapter, {:cli_resolved, result})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:query, request_id, prompt, opts}, _from, state) do
    session_id = Keyword.get(opts, :session_id, "default")

    case ensure_connected(state) do
      {:ok, connected_state} ->
        message = Input.user_message(prompt, session_id)
        :exec.send(connected_state.os_pid, message <> "\n")
        {:reply, :ok, %{connected_state | current_request: request_id}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:health, _from, state) do
    health =
      case state do
        %{status: :provisioning} -> {:unhealthy, :provisioning}
        %{os_pid: pid} when not is_nil(pid) -> :healthy
        _ -> {:unhealthy, :not_connected}
      end

    {:reply, health, state}
  end

  @impl GenServer
  def handle_call({:control_request, subtype, params}, from, state) do
    case state.os_pid do
      nil ->
        {:reply, {:error, :not_connected}, state}

      os_pid ->
        {request_id, new_counter} = next_request_id(state.control_counter)

        case build_control_json(subtype, request_id, params) do
          {:error, _} = error ->
            {:reply, error, state}

          json ->
            :exec.send(os_pid, json <> "\n")

            pending = Map.put(state.pending_control_requests, request_id, from)
            schedule_control_timeout(request_id)

            {:noreply, %{state | control_counter: new_counter, pending_control_requests: pending}}
        end
    end
  end

  @impl GenServer
  def handle_call(:get_server_info, _from, state) do
    {:reply, {:ok, state.server_info}, state}
  end

  def handle_call(:interrupt, _from, %{os_pid: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:interrupt, _from, state) do
    {request_id, new_counter} = next_request_id(state.control_counter)
    json = Control.interrupt_request(request_id)
    :exec.send(state.os_pid, json <> "\n")
    {:reply, :ok, %{state | control_counter: new_counter}}
  end

  @impl GenServer
  def handle_info({:cli_resolved, {:ok, {executable, args, streaming_opts}}}, state) do
    case open_cli_port(executable, args, state, streaming_opts) do
      {:ok, os_pid} ->
        new_state = %{state | os_pid: os_pid, buffer: "", stderr_lines: [], status: :initializing}
        send_initialize_handshake(new_state)

      {:error, reason} ->
        Adapter.notify_status(state.session, {:error, reason})
        {:noreply, %{state | status: :disconnected}}
    end
  end

  def handle_info({:cli_resolved, {:error, reason}}, state) do
    Adapter.notify_status(state.session, {:error, reason})
    {:noreply, %{state | status: :disconnected}}
  end

  # erlexec stdout — JSON protocol messages from CLI
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    new_buffer = state.buffer <> data

    # Extract complete lines FIRST — only the remaining incomplete line counts against
    # the buffer limit. This prevents false overflow when many complete JSON messages
    # are waiting to be processed.
    {lines, remaining_buffer} = extract_lines(new_buffer)

    new_state =
      Enum.reduce(lines, %{state | buffer: remaining_buffer}, fn line, acc_state ->
        process_line(line, acc_state)
      end)

    if byte_size(new_state.buffer) > new_state.max_buffer_size do
      Logger.error("Buffer overflow: single incomplete line is #{byte_size(new_state.buffer)} bytes (max #{new_state.max_buffer_size})")

      {:noreply, handle_port_disconnect(new_state, {:buffer_overflow, byte_size(new_state.buffer)})}
    else
      {:noreply, new_state}
    end
  end

  # erlexec stderr — warnings and errors from CLI/sandbox
  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    lines = data |> String.split("\n") |> Enum.reject(&(&1 == ""))
    for line <- lines, do: Logger.warning("[cli stderr] #{line}")
    {:noreply, %{state | stderr_lines: state.stderr_lines ++ lines}}
  end

  # erlexec process exit — guaranteed to arrive AFTER all stdout/stderr
  def handle_info({:DOWN, os_pid, :process, _erlang_pid, reason}, %{os_pid: os_pid} = state) do
    case reason do
      :normal ->
        if state.status in [:provisioning, :initializing] do
          stderr_text = Enum.join(state.stderr_lines, "\n")
          Logger.error("[cli] exited during #{state.status} with no error (exit 0)#{if stderr_text != "", do: "\n#{stderr_text}"}")
        end
        {:noreply, handle_port_disconnect(state, :normal)}

      {:exit_status, raw_status} ->
        {:status, code} = :exec.status(raw_status)
        stderr_text = Enum.join(state.stderr_lines, "\n")
        if stderr_text != "", do: Logger.error("[cli exit=#{code}] #{stderr_text}")
        {:noreply, handle_port_disconnect(state, {:cli_exit, code})}

      other ->
        Logger.error("[cli] process died: #{inspect(other)}")
        {:noreply, handle_port_disconnect(state, {:port_closed, other})}
    end
  end

  def handle_info({:control_timeout, request_id}, state) do
    case Map.pop(state.pending_control_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {{:initialize, session}, remaining} ->
        Adapter.notify_status(session, {:error, :initialize_timeout})
        {:noreply, %{state | pending_control_requests: remaining, status: :disconnected}}

      {from, remaining} ->
        GenServer.reply(from, {:error, :control_timeout})
        {:noreply, %{state | pending_control_requests: remaining}}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("[cli] unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.os_pid do
      # Interrupt first — tells the CLI to stop generating before we kill it.
      # Without this, the CLI keeps consuming the API until it notices the broken pipe.
      try do
        {request_id, _} = next_request_id(state.control_counter)
        :exec.send(state.os_pid, Control.interrupt_request(request_id) <> "\n")
      catch
        _, _ -> :ok
      end

      try do
        :exec.stop(state.os_pid)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ============================================================================
  # Private Functions - Port Management
  # ============================================================================

  defp handle_port_disconnect(state, error) do
    for {_req_id, pending} <- state.pending_control_requests do
      case pending do
        {:initialize, session} ->
          Adapter.notify_status(session, {:error, error})

        from ->
          GenServer.reply(from, {:error, error})
      end
    end

    if state.current_request do
      Adapter.notify_error(state.session, state.current_request, error)
    end

    %{state | os_pid: nil, current_request: nil, buffer: "", stderr_lines: [], status: :disconnected, pending_control_requests: %{}}
  end

  defp send_initialize_handshake(state) do
    agents = Keyword.get(state.session_options, :agents)
    hooks_map = Keyword.get(state.session_options, :hooks)
    can_use_tool = Keyword.get(state.session_options, :can_use_tool)

    {_registry, hooks_wire} = HookRegistry.new(hooks_map, can_use_tool)

    sdk_mcp_server_names =
      case Map.keys(state.sdk_mcp_servers) do
        [] -> nil
        names -> names
      end

    {request_id, new_counter} = next_request_id(state.control_counter)
    json = Control.initialize_request(request_id, hooks_wire, agents, sdk_mcp_server_names)
    :exec.send(state.os_pid, json <> "\n")

    pending = Map.put(state.pending_control_requests, request_id, {:initialize, state.session})
    schedule_control_timeout(request_id)

    {:noreply, %{state | control_counter: new_counter, pending_control_requests: pending}}
  end

  defp ensure_connected(%{status: :provisioning}), do: {:error, :provisioning}
  defp ensure_connected(%{status: :initializing}), do: {:error, :initializing}

  defp ensure_connected(%{os_pid: nil, status: :disconnected} = state) do
    case spawn_cli(state) do
      {:ok, os_pid} ->
        Adapter.notify_status(state.session, :ready)
        {:ok, %{state | os_pid: os_pid, buffer: "", stderr_lines: [], status: :ready}}

      {:error, reason} ->
        Logger.error("Failed to reconnect to CLI: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_connected(state), do: {:ok, state}

  # Resolves the CLI binary and builds the command. This may trigger auto-install
  # which can take seconds, so call from a Task during initial provisioning.
  defp resolve_cli(session_options, _api_key) do
    streaming_opts = Keyword.put(session_options, :input_format, :stream_json)
    resume_session_id = Keyword.get(session_options, :resume)

    case Resolver.find_binary(streaming_opts) do
      {:ok, executable} ->
        args = Command.build_args("", streaming_opts, resume_session_id)
        {:ok, {executable, List.delete_at(args, -1), streaming_opts}}

      {:error, :not_found} ->
        {:error, {:cli_not_found, Installer.cli_not_found_message()}}

      {:error, reason} ->
        {:error, {:cli_not_found, "CLI resolution failed: #{inspect(reason)}"}}
    end
  end

  # Synchronous spawn -- resolves binary and opens port in the same process.
  # Used by ensure_connected for reconnection (binary already installed, fast path).
  defp spawn_cli(state) do
    case resolve_cli(state.session_options, state.api_key) do
      {:ok, {executable, args, streaming_opts}} ->
        open_cli_port(executable, args, state, streaming_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_cli_port(executable, args, state, opts) do
    cmd_string = build_shell_command(executable, args, state, opts)
    Logger.info("[cli spawn] #{cmd_string}")

    # build_shell_command embeds env vars, cwd, and agentbox wrapping into the string.
    # We run it via /bin/sh -c so all that shell setup works, but use erlexec instead
    # of Erlang ports for proper stdout/stderr separation and guaranteed message ordering.
    exec_opts = [
      :stdin,
      {:stdout, self()},
      {:stderr, self()},
      :monitor
    ]

    case :exec.run([~c"/bin/sh", ~c"-c", to_charlist(cmd_string)], exec_opts) do
      {:ok, _erlang_pid, os_pid} ->
        {:ok, os_pid}

      {:error, reason} ->
        {:error, {:port_open_failed, reason}}
    end
  end

  defp build_shell_command(executable, args, state, opts) do
    env_prefix =
      state
      |> prepare_env()
      |> Enum.map_join(" ", fn {key, value} ->
        "#{key}=#{shell_escape(to_string(value))}"
      end)

    cwd = Keyword.get(opts, :cwd)

    cwd_prefix =
      case cwd do
        nil -> ""
        cwd_path -> "cd #{shell_escape(cwd_path)} && "
      end

    cmd_string = Enum.map_join([executable | args], " ", &shell_escape/1)

    case Keyword.get(state.session_options, :agentbox) do
      %{} = ab ->
        ab_exe = shell_escape(to_string(ab[:executable] || ab["executable"]))
        profile = shell_escape(to_string(ab[:profile] || ab["profile"]))
        config = ab[:config] || ab["config"]
        workdir = ab[:workdir] || ab["workdir"] || cwd || "."

        config_flag = if config, do: " --config #{shell_escape(to_string(config))}", else: ""
        connect_flags = Enum.map_join(List.wrap(ab[:connect] || ab["connect"] || []), " ", fn p -> "--connect #{p}" end)
        connect_part = if connect_flags == "", do: "", else: " #{connect_flags}"
        "#{cwd_prefix}#{env_prefix}exec #{ab_exe}#{config_flag} --profile #{profile} --workdir #{shell_escape(to_string(workdir))}#{connect_part} -- #{cmd_string}"

      _ ->
        "#{cwd_prefix}#{env_prefix}exec #{cmd_string}"
    end
  end

  defp prepare_env(state) do
    state.session_options
    |> build_env(state.api_key)
    |> Map.to_list()
  end

  # ============================================================================
  # Testable Functions (public but not part of API)
  # ============================================================================

  @doc false
  def sdk_env_vars do
    %{
      "CLAUDE_CODE_ENTRYPOINT" => "sdk-ex",
      "CLAUDE_AGENT_SDK_VERSION" => ClaudeCode.version()
    }
  end

  @doc false
  def build_env(session_options, api_key) do
    user_env = Keyword.get(session_options, :env, %{})

    System.get_env()
    |> Map.merge(sdk_env_vars())
    |> Map.merge(user_env)
    |> maybe_put_api_key(api_key)
    |> maybe_put_file_checkpointing(session_options)
  end

  defp maybe_put_api_key(env, api_key) when is_binary(api_key) do
    Map.put(env, "ANTHROPIC_API_KEY", api_key)
  end

  defp maybe_put_api_key(env, _), do: env

  defp maybe_put_file_checkpointing(env, opts) do
    if Keyword.get(opts, :enable_file_checkpointing, false) do
      Map.put(env, "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "true")
    else
      env
    end
  end

  @doc false
  # Semicolons must be escaped because they are command separators in shell.
  # This is critical for system env vars like LS_COLORS that contain semicolons.
  def shell_escape(str) when is_binary(str) do
    if str == "" or String.contains?(str, @shell_special_chars) do
      "'" <> String.replace(str, "'", "'\\''") <> "'"
    else
      str
    end
  end

  def shell_escape(str), do: shell_escape(to_string(str))

  @doc false
  def extract_lines(buffer) do
    case String.split(buffer, "\n") do
      [incomplete] -> {[], incomplete}
      lines -> {List.delete_at(lines, -1), List.last(lines)}
    end
  end

  # ============================================================================
  # Private Functions - Message Processing
  # ============================================================================

  defp process_line("", state), do: state

  defp process_line(line, state) do
    case Jason.decode(line) do
      {:ok, json} ->
        case Control.classify(json) do
          {:control_response, msg} ->
            handle_control_response(msg, state)

          {:control_request, msg} ->
            handle_inbound_control_request(msg, state)

          {:message, json_msg} ->
            handle_sdk_message(json_msg, state)
        end

      {:error, _} ->
        Logger.warning("[cli stdout non-json] #{line}")
        state
    end
  end

  defp handle_sdk_message(json, %{current_request: nil} = state) do
    # No active request — but still log error results (e.g. startup failures)
    case json do
      %{"is_error" => true, "errors" => errors} when is_list(errors) ->
        Logger.error("[cli error] #{Enum.join(errors, "; ")}")
      %{"is_error" => true, "result" => result} when is_binary(result) ->
        Logger.error("[cli error] #{result}")
      _ -> :ok
    end
    state
  end

  defp handle_sdk_message(json, state) do
    case Parser.parse_message(json) do
      {:ok, message} ->
        Adapter.notify_message(state.session, state.current_request, message)

        if match?(%ResultMessage{}, message) do
          Adapter.notify_done(state.session, state.current_request, :completed)
          %{state | current_request: nil}
        else
          state
        end

      {:error, _} ->
        Logger.warning("[cli] failed to parse SDK message: #{String.slice(inspect(json), 0, 200)}")
        state
    end
  end

  defp handle_control_response(msg, state) do
    case Control.parse_control_response(msg) do
      {:ok, request_id, response} ->
        case Map.pop(state.pending_control_requests, request_id) do
          {nil, _} ->
            # CLI sends control responses for its own internal operations (e.g. MCP server
            # handshakes) with UUID request IDs we never generated. Safe to ignore.
            Logger.debug("Received control response for unknown request: #{request_id}")
            state

          {{:initialize, session}, remaining} ->
            Adapter.notify_status(session, :ready)
            %{state | pending_control_requests: remaining, server_info: response, status: :ready}

          {from, remaining} ->
            GenServer.reply(from, {:ok, response})
            %{state | pending_control_requests: remaining}
        end

      {:error, request_id, error_msg} ->
        case Map.pop(state.pending_control_requests, request_id) do
          {nil, _} ->
            Logger.debug("Received control error for unknown request: #{request_id}")
            state

          {{:initialize, session}, remaining} ->
            Adapter.notify_status(session, {:error, {:initialize_failed, error_msg}})
            %{state | pending_control_requests: remaining, status: :disconnected}

          {from, remaining} ->
            GenServer.reply(from, {:error, error_msg})
            %{state | pending_control_requests: remaining}
        end
    end
  end

  defp handle_inbound_control_request(msg, state) do
    request_id = get_in(msg, ["request_id"])
    request = get_in(msg, ["request"])
    subtype = get_in(request, ["subtype"])

    response_data =
      case subtype do
        "can_use_tool" ->
          handle_can_use_tool(request, state)

        "hook_callback" ->
          handle_hook_callback(request, state)

        "mcp_message" ->
          server_name = request["server_name"]
          jsonrpc = request["message"]
          mcp_response = handle_mcp_message(server_name, jsonrpc, state.sdk_mcp_servers)
          %{"mcp_response" => mcp_response}

        _ ->
          Logger.warning("Received unhandled control request: #{subtype}")
          nil
      end

    response =
      if response_data do
        Control.success_response(request_id, response_data)
      else
        Control.error_response(request_id, "Not implemented: #{subtype}")
      end

    if state.os_pid, do: :exec.send(state.os_pid, response <> "\n")
    state
  end

  defp handle_can_use_tool(request, state) do
    case state.hook_registry.can_use_tool do
      nil ->
        # No can_use_tool callback -- allow by default
        %{"behavior" => "allow"}

      callback ->
        input = %{
          tool_name: request["tool_name"],
          input: request["input"],
          permission_suggestions: request["permission_suggestions"],
          blocked_path: request["blocked_path"]
        }

        tool_use_id = nil
        result = Hook.invoke(callback, input, tool_use_id)
        HookResponse.to_can_use_tool_wire(result)
    end
  end

  defp handle_hook_callback(request, state) do
    callback_id = request["callback_id"]
    input = atomize_keys(request["input"])
    tool_use_id = request["tool_use_id"]

    case HookRegistry.lookup(state.hook_registry, callback_id) do
      {:ok, callback} ->
        result = Hook.invoke(callback, input, tool_use_id)
        HookResponse.to_hook_callback_wire(result)

      :error ->
        Logger.warning("Unknown hook callback ID: #{callback_id}")
        %{}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(other), do: other

  @doc false
  def extract_sdk_mcp_servers(opts) do
    case Keyword.get(opts, :mcp_servers) do
      nil ->
        %{}

      servers when is_map(servers) ->
        servers
        |> Enum.flat_map(fn
          {name, module} when is_atom(module) ->
            if MCPServer.sdk_server?(module), do: [{name, {module, %{}}}], else: []

          {name, %{module: module} = config} when is_atom(module) ->
            if MCPServer.sdk_server?(module) do
              [{name, {module, Map.get(config, :assigns, %{})}}]
            else
              []
            end

          _ ->
            []
        end)
        |> Map.new()
    end
  end

  @doc false
  def handle_mcp_message(server_name, jsonrpc, sdk_mcp_servers) do
    case Map.get(sdk_mcp_servers, server_name) do
      nil ->
        %{
          "jsonrpc" => "2.0",
          "id" => jsonrpc["id"],
          "error" => %{"code" => -32_601, "message" => "Server '#{server_name}' not found"}
        }

      {module, assigns} ->
        MCPRouter.handle_request(module, jsonrpc, assigns)
    end
  end

  defp next_request_id(counter) do
    {Control.generate_request_id(counter), counter + 1}
  end

  defp build_control_json(:initialize, request_id, params) do
    hooks = Map.get(params, :hooks)
    agents = Map.get(params, :agents)
    sdk_mcp_servers = Map.get(params, :sdk_mcp_servers)
    Control.initialize_request(request_id, hooks, agents, sdk_mcp_servers)
  end

  defp build_control_json(:set_model, request_id, %{model: model}) do
    Control.set_model_request(request_id, model)
  end

  defp build_control_json(:set_permission_mode, request_id, %{mode: mode}) do
    Control.set_permission_mode_request(request_id, to_string(mode))
  end

  defp build_control_json(:rewind_files, request_id, %{user_message_id: id}) do
    Control.rewind_files_request(request_id, id)
  end

  defp build_control_json(:mcp_status, request_id, _params) do
    Control.mcp_status_request(request_id)
  end

  defp build_control_json(subtype, _request_id, _params) do
    {:error, {:unknown_control_subtype, subtype}}
  end

  defp schedule_control_timeout(request_id) do
    Process.send_after(self(), {:control_timeout, request_id}, @control_timeout)
  end
end
