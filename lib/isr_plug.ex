defmodule ISRPlug do
  @moduledoc """
  A generic Plug implementing an Incremental Static Regeneration (ISR) pattern.

  This plug allows serving cached data (fresh or stale) quickly while triggering
  non-blocking background tasks to refresh expired data. It's designed to be
  flexible and reusable in Phoenix applications.

  ## Configuration

  The plug is configured via options passed during the `plug` call in the router:

  ```elixir
  plug ISRPlug,
    # --- Required ---
    fetch_fun: &YourModule.your_fetch_function/1,
    apply_fun: &YourModule.your_apply_function/2,

    # --- Optional ---
    extract_data_fun: &YourModule.your_extract_function/1,
    cache_key_fun: &YourModule.your_cache_key_function/1,
    ets_table: :my_specific_isr_cache,
    cache_ttl_ms: 60_000, # 1 minute
    stale_serving_ttl_ms: 3_600_000, # 1 hour
    error_handler_fun: &YourModule.your_error_handler/2
  ```

  See the function documentation for `init/1` for details on each option.
  """

  @behaviour Plug
  require Logger

  @default_ets_table :isr_plug_cache
  @default_cache_ttl_ms 60_000 # 1 minute
  @default_stale_serving_ttl_ms 3_600_000 # 1 hour

  @doc """
  Initializes the plug with configuration options.

  ## Options

    * `:fetch_fun` (**required**): A 1-arity function
      `(extracted_data :: any()) -> {:ok, value :: any()} | {:error, reason :: any()}`.
      Performs the data retrieval.

    * `:apply_fun` (**required**): A 2-arity function
      `(conn :: Plug.Conn.t(), value :: any()) -> Plug.Conn.t()`.
      Applies the successfully retrieved `value` (fresh or stale) to the connection.
      Must return a `Plug.Conn.t()`.

    * `:extract_data_fun` (*optional*): A 1-arity function
      `(conn :: Plug.Conn.t()) -> any()`.
      Extracts necessary data from the `conn` to be passed to `:fetch_fun`.
      Defaults to `fn _conn -> %{} end`.

    * `:cache_key_fun` (*optional*): A 1-arity function
      `(conn :: Plug.Conn.t()) -> term()`.
      Generates a unique ETS key based on the connection.
      Defaults to `fn _conn -> :isr_plug_default_key end`. Ensure this generates
      distinct keys if the fetched data varies based on connection properties.

    * `:ets_table` (*optional*): Atom name for the ETS table.
      Defaults to `#{@default_ets_table}`. Use distinct names if using the plug
      multiple times for different purposes.

    * `:cache_ttl_ms` (*optional*): Integer milliseconds for how long data is
      considered fresh. Defaults to `#{@default_cache_ttl_ms}` (1 minute).

    * `:stale_serving_ttl_ms` (*optional*): Integer milliseconds *after* expiry
      during which stale data can be served while refreshing.
      Defaults to `#{@default_stale_serving_ttl_ms}` (1 hour).

    * `:error_handler_fun` (*optional*): A 2-arity function
      `(conn :: Plug.Conn.t(), reason :: any()) -> Plug.Conn.t()`.
      Called only when a *synchronous* fetch fails. Defaults to a function that
      logs the error and returns the original `conn`.

  This function also initializes the specified ETS table if it doesn't already exist.
  """
  @impl Plug
  def init(opts) do
    # Ensure required options are present
    Keyword.fetch!(opts, :fetch_fun)
    Keyword.fetch!(opts, :apply_fun)

    # Validate function arities (basic check)
    validate_fun!(opts, :fetch_fun, 1, "extracted_data")
    validate_fun!(opts, :apply_fun, 2, "(conn, value)")

    # Set defaults and validate optional functions
    opts = Keyword.put_new_lazy(opts, :extract_data_fun, fn -> fn _conn -> %{} end end)
    validate_fun!(opts, :extract_data_fun, 1, "conn")

    opts = Keyword.put_new_lazy(opts, :cache_key_fun, fn -> fn _conn -> :isr_plug_default_key end end)
    validate_fun!(opts, :cache_key_fun, 1, "conn")

    opts = Keyword.put_new(opts, :ets_table, @default_ets_table)
    opts = Keyword.put_new(opts, :cache_ttl_ms, @default_cache_ttl_ms)
    opts = Keyword.put_new(opts, :stale_serving_ttl_ms, @default_stale_serving_ttl_ms)

    opts = Keyword.put_new_lazy(opts, :error_handler_fun, fn -> &default_error_handler/2 end)
    validate_fun!(opts, :error_handler_fun, 2, "(conn, reason)")


    # Initialize ETS table if it doesn't exist
    ets_table = opts[:ets_table]
    # Use :named_table property for idempotent creation check
    # Check if the table exists by trying to get info; :undefined means it doesn't exist.
    unless :ets.info(ets_table, :name) == ets_table do
      :ets.new(ets_table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      Logger.info("[#{__MODULE__}] Initialized ETS table: #{inspect(ets_table)}")
    end

    opts
  end

  @doc """
  Processes the connection according to the ISR logic.

  1. Extracts data and determines the cache key using configured functions.
  2. Checks the ETS cache.
  3. Handles cache hits (fresh or stale).
  4. If stale, serves stale data and triggers a background refresh task.
  5. Handles cache misses or expired stale TTL by fetching synchronously.
  6. If synchronous fetch fails, calls the error handler.
  7. If data is available (fresh, stale, or newly fetched), applies it using the configured function.
  8. Returns the (potentially modified) connection.
  """
  @impl Plug
  def call(conn, opts) do
    # Extract configuration
    extract_data_fun = opts[:extract_data_fun]
    cache_key_fun = opts[:cache_key_fun]
    ets_table = opts[:ets_table]

    # --- Core ISR Logic ---
    extracted_data = extract_data_fun.(conn)
    cache_key = cache_key_fun.(conn)
    log_prefix = "[#{__MODULE__}][#{inspect(cache_key)}]"

    # 1. Check Cache
    case :ets.lookup(ets_table, cache_key) do
      # Cache Hit
      [{^cache_key, value, expiry_ts, stale_serve_until_ts}] ->
        handle_cache_hit_and_proceed(conn, log_prefix, value, expiry_ts, stale_serve_until_ts, opts, extracted_data, cache_key)

      # Cache Miss
      [] ->
        Logger.debug("#{log_prefix} Cache Miss. Fetching synchronously.")
        # Perform initial synchronous fetch
        handle_sync_fetch_and_proceed(conn, log_prefix, opts, extracted_data, cache_key)
    end
  end

  # --- Private Processing Logic ---

  # Handles the logic when an item is found in the cache
  defp handle_cache_hit_and_proceed(conn, log_prefix, value, expiry_ts, stale_serve_until_ts, opts, extracted_data, cache_key) do
    now = System.monotonic_time()
    apply_fun = opts[:apply_fun]

    cond do
      # Fresh Hit
      now < expiry_ts ->
        Logger.debug("#{log_prefix} Cache Hit (Fresh)")
        apply_value(conn, value, apply_fun)

      # Stale Hit (within stale serving window)
      now < stale_serve_until_ts ->
        Logger.debug("#{log_prefix} Cache Hit (Stale). Serving stale, triggering refresh.")
        # Serve stale value immediately
        conn_with_stale = apply_value(conn, value, apply_fun)

        # Trigger background refresh
        # Explicitly pass necessary opts to the background task
        ets_table = opts[:ets_table]
        fetch_fun = opts[:fetch_fun]
        cache_ttl_ms = opts[:cache_ttl_ms]
        stale_ttl_ms = opts[:stale_serving_ttl_ms]
        Task.start(fn -> perform_background_refresh(log_prefix, ets_table, fetch_fun, cache_ttl_ms, stale_ttl_ms, extracted_data, cache_key) end)

        conn_with_stale

      # Stale Hit (expired stale TTL)
      true ->
        Logger.warning("#{log_prefix} Cache Hit (Expired Stale TTL). Fetching synchronously.")
        # Treat as cache miss, fetch synchronously
        handle_sync_fetch_and_proceed(conn, log_prefix, opts, extracted_data, cache_key)
    end
  end

  # Handles the logic for synchronous fetching (cache miss or expired stale TTL)
  defp handle_sync_fetch_and_proceed(conn, log_prefix, opts, extracted_data, cache_key) do
    ets_table = opts[:ets_table]
    fetch_fun = opts[:fetch_fun]
    cache_ttl_ms = opts[:cache_ttl_ms]
    stale_ttl_ms = opts[:stale_serving_ttl_ms]
    error_handler_fun = opts[:error_handler_fun]
    apply_fun = opts[:apply_fun]

    case fetch_synchronously_and_cache(log_prefix, ets_table, cache_key, fetch_fun, extracted_data, cache_ttl_ms, stale_ttl_ms) do
      {:ok, value} ->
        # Fetched successfully, apply the new value
        apply_value(conn, value, apply_fun)
      {:error, reason} ->
        # Sync fetch failed, call the error handler
        Logger.error("#{log_prefix} Synchronous fetch failed: #{inspect(reason)}")
        error_handler_fun.(conn, reason)
    end
  end

  # Applies the value using the configured apply_fun
  defp apply_value(conn, value, apply_fun) do
    if not is_nil(value) do
      apply_fun.(conn, value)
    else
      Logger.warning("[#{__MODULE__}] No value available to apply (sync fetch likely failed and error handler didn't halt). Passing conn through.")
      conn
    end
  end

  # --- Private Fetching & Caching Helpers ---

  defp fetch_synchronously_and_cache(log_prefix, ets_table, cache_key, fetch_fun, extracted_data, cache_ttl_ms, stale_ttl_ms) do
    Logger.debug("#{log_prefix} Fetching synchronously...")
    case fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
      {:ok, value} ->
        update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms)
        {:ok, value}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_background_refresh(log_prefix, ets_table, fetch_fun, cache_ttl_ms, stale_ttl_ms, extracted_data, cache_key) do
    Logger.debug("#{log_prefix} Performing background refresh...")
    case fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
      {:ok, value} ->
        update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms)
        Logger.debug("#{log_prefix} Background refresh successful.")
      {:error, reason} ->
        Logger.error("#{log_prefix} Background refresh failed: #{inspect(reason)}")
    end
    :ok
  end

  defp fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
    try do
      case fetch_fun.(extracted_data) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        other ->
          Logger.warning("#{log_prefix} Fetch function returned unexpected value: #{inspect(other)}. Expected {:ok, value} or {:error, reason}. Treating as error.")
          {:error, {:unexpected_return, other}}
      end
    rescue
      e ->
        err = Exception.format(:error, e, __STACKTRACE__)
        Logger.error("#{log_prefix} Unhandled error during fetch_fun execution: #{err}")
        {:error, {:exception, err}}
    end
  end

  defp update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms) do
    now = System.monotonic_time()
    expiry_ts = now + System.convert_time_unit(cache_ttl_ms, :millisecond, :native)
    stale_serve_until_ts = expiry_ts + System.convert_time_unit(stale_ttl_ms, :millisecond, :native)

    :ets.insert(ets_table, {cache_key, value, expiry_ts, stale_serve_until_ts})
    Logger.debug("#{log_prefix} Updated cache.")
  end

  # Default error handler if synchronous fetch fails
  defp default_error_handler(conn, reason) do
    log_prefix = "[#{__MODULE__}][DefaultErrorHandler]"
    Logger.error("#{log_prefix} Synchronous fetch failed: #{inspect(reason)}. Passing connection through unchanged.")
    conn
  end

  # Helper for init options validation
  defp validate_fun!(opts, key, arity, signature) do
    fun = Keyword.get(opts, key)
    if fun && !is_function(fun, arity) do
      raise ArgumentError, "Option :#{key} must be a function with arity #{arity} #{signature}"
    end
  end
end
