defmodule ISRPlug.CacheManager do
  @moduledoc """
  Manages ETS tables for ISRPlug. Add to your Application supervisor.
  """
  use GenServer
  require Logger
  alias ISRPlug

  # --- Public API ---

  @doc """
  Starts the cache manager. Called by the application supervisor.
  Opts:
    - table_names: list of atoms, ETS tables to create. Defaults to [:isr_plug_cache]
  """
  def start_link(opts) do
    # Use the module name as the GenServer registered name
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Default to the table name expected by ISRPlug if none are passed
    default_table = ISRPlug.default_ets_table()
    table_names = Keyword.get(opts, :table_names, [default_table]) |> List.wrap() |> Enum.uniq()

    ets_options = [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ]

    Logger.info("[#{__MODULE__}] Initializing ETS tables: #{inspect(table_names)}")

    # Create each requested table
    Enum.each(table_names, fn table_name ->
      create_table_if_needed(table_name, ets_options)
    end)

    # No real state needed after init
    {:ok, %{managed_tables: table_names}}
  end

  # --- Private Helpers ---

  defp create_table_if_needed(table_name, ets_options) when is_atom(table_name) do
    # Check if table already exists (important for restarts/idempotency)
    unless :ets.info(table_name, :name) == table_name do
      Logger.info("[#{inspect(__MODULE__)}] Creating ETS table: #{inspect(table_name)}")
      :ets.new(table_name, ets_options)
    else
      Logger.info("[#{inspect(__MODULE__)}] ETS table already exists: #{inspect(table_name)}")
    end
  rescue
    # If creation fails, log and crash supervisor init (prevents broken app state)
    error ->
      Logger.error(
        "[#{inspect(__MODULE__)}] Failed to create ETS table #{inspect(table_name)}: #{inspect(error)}"
      )

      reraise error, __STACKTRACE__
  end

  defp create_table_if_needed(invalid_name, _ets_options) do
    msg =
      "Invalid ETS table name provided to #{__MODULE__}: #{inspect(invalid_name)}. Must be an atom."

    Logger.error(msg)
    raise ArgumentError, msg
  end
end
