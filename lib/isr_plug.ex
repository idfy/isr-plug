defmodule ISRPlug do
  # --- Defaults ---
  @default_ets_table :isr_plug_cache
  # 1 minute
  @default_cache_ttl_ms 60_000
  # 1 hour
  @default_stale_serving_ttl_ms 3_600_000

  @moduledoc """
  A generic Plug implementing an Incremental Static Regeneration (ISR) pattern.

  This plug allows serving cached data (fresh or stale) quickly while triggering
  non-blocking background tasks to refresh expired data. It's designed to be
  flexible and reusable in Phoenix applications.

  ## Setup

  1.  **Add Cache Manager to Supervisor:** Ensure the ETS cache table exists
      when your application starts by adding `ISRPlug.CacheManager` to your
      application's supervision tree (`lib/my_app/application.ex`):

      ```elixir
      # lib/my_app/application.ex
      def start(_type, _args) do
        children = [
          # ... other children
          MyApp.Repo,
          MyAppWeb.Endpoint,

          # Add the cache manager. Creates :isr_plug_cache by default.
          ISRPlug.CacheManager
          # OR: Specify custom/multiple tables if needed
          # {ISRPlug.CacheManager, table_names: [:my_isr_cache, :another_cache]}
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end
      ```

      You need to create the `lib/isr_plug/cache_manager.ex` file (provided in the previous explanation)
      or ensure it's part of the dependency package if this Plug is distributed.

  2.  **Use the Plug:** Add `plug ISRPlug` in your router pipeline, configuring
      it with your functions and ensuring the `:ets_table` option matches a
      table name managed by `ISRPlug.CacheManager`.

      ```elixir
      # In your router.ex
      pipeline :isr_protected do
        plug :accepts, ["html"]
        # ... other plugs
        plug ISRPlug,
          fetch_fun: &MyData.fetch_live_data/1,
          apply_fun: &MyPageController.apply_data_to_conn/2,
          cache_key_fun: &MyPageController.generate_cache_key/1,
          ets_table: :isr_plug_cache # Must match a table from CacheManager
          # ... other options like cache_ttl_ms, etc.
      end
      ```

  ## Configuration Options (for the `plug` call)

  The plug is configured via options passed during the `plug` call in the router:

  *   `:fetch_fun` (**required**): A 1-arity function
      `(extracted_data :: any()) -> {:ok, value :: any()} | {:error, reason :: any()}`.
      Performs the data retrieval.

  *   `:apply_fun` (**required**): A 2-arity function
      `(conn :: Plug.Conn.t(), value :: any()) -> Plug.Conn.t()`.
      Applies the successfully retrieved `value` (fresh or stale) to the connection.
      Must return a `Plug.Conn.t()`.

  *   `:extract_data_fun` (*optional*): A 1-arity function
      `(conn :: Plug.Conn.t()) -> any()`.
      Extracts necessary data from the `conn` to be passed to `:fetch_fun`.
      Defaults to `fn _conn -> %{} end`.

  *   `:cache_key_fun` (*optional*): A 1-arity function
      `(conn :: Plug.Conn.t()) -> term()`.
      Generates a unique ETS key based on the connection.
      Defaults to `fn _conn -> :isr_plug_default_key end`. Ensure this generates
      distinct keys if the fetched data varies based on connection properties.

  *   `:ets_table` (*optional*): Atom name for the ETS table.
      Defaults to `#{@default_ets_table}`. Must match a name managed by `ISRPlug.CacheManager`.
      Use distinct names if using the plug multiple times for different purposes.

  *   `:cache_ttl_ms` (*optional*): Integer milliseconds for how long data is
      considered fresh. Defaults to `#{@default_cache_ttl_ms}` (1 minute).

  *   `:stale_serving_ttl_ms` (*optional*): Integer milliseconds *after* expiry
      during which stale data can be served while refreshing.
      Defaults to `#{@default_stale_serving_ttl_ms}` (1 hour).

  *   `:error_handler_fun` (*optional*): A 2-arity function
      `(conn :: Plug.Conn.t(), reason :: any()) -> Plug.Conn.t()`.
      Called only when a *synchronous* fetch fails (cache miss or expired stale TTL).
      Defaults to a function that logs the error and returns the original `conn`.

  """

  @behaviour Plug
  require Logger

  @doc """
  Returns the default ETS table name used by ISRPlug.
  Useful for configuring the default `ISRPlug.CacheManager`.
  """
  @spec default_ets_table() :: atom()
  def default_ets_table, do: @default_ets_table

  @doc """
  Initializes the plug configuration options.

  NOTE: This function **no longer creates the ETS table**. Ensure the table
  is created at application startup by adding `ISRPlug.CacheManager`
  (or your own manager) to your application supervisor.

  This function validates the provided options and sets defaults.
  """
  @impl Plug
  def init(opts) do
    # --- Option validation and defaulting ---
    Keyword.fetch!(opts, :fetch_fun)
    Keyword.fetch!(opts, :apply_fun)

    validate_fun!(opts, :fetch_fun, 1, "extracted_data")
    validate_fun!(opts, :apply_fun, 2, "(conn, value)")

    opts = Keyword.put_new(opts, :extract_data_fun, &ISRPlug.default_extract_data/1)
    validate_fun!(opts, :extract_data_fun, 1, "conn")

    opts = Keyword.put_new(opts, :cache_key_fun, &ISRPlug.default_cache_key/1)
    validate_fun!(opts, :cache_key_fun, 1, "conn")

    opts = Keyword.put_new(opts, :error_handler_fun, &ISRPlug.default_error_handler/2)
    validate_fun!(opts, :error_handler_fun, 2, "(conn, reason)")

    opts = Keyword.put_new(opts, :ets_table, @default_ets_table)
    opts = Keyword.put_new(opts, :cache_ttl_ms, @default_cache_ttl_ms)
    opts = Keyword.put_new(opts, :stale_serving_ttl_ms, @default_stale_serving_ttl_ms)
    # --- End option validation ---

    # Return the validated/defaulted options
    opts
  end

  @doc """
  Processes the connection according to the ISR logic.

  Assumes the ETS table specified in the `:ets_table` option (passed during `init/1`)
  already exists, managed externally (e.g., by `ISRPlug.CacheManager`).
  """
  @impl Plug
  def call(conn, opts) do
    # Extract configuration needed for this request
    extract_data_fun = opts[:extract_data_fun]
    cache_key_fun = opts[:cache_key_fun]
    # Reads table name from opts passed by init
    ets_table = opts[:ets_table]

    # --- Core ISR Logic ---
    extracted_data = extract_data_fun.(conn)
    cache_key = cache_key_fun.(conn)
    # Include table name in log prefix for clarity when using multiple tables
    log_prefix = "[#{__MODULE__}][#{inspect(ets_table)}][#{inspect(cache_key)}]"

    # 1. Check Cache
    # This lookup expects the table to exist because CacheManager created it
    case :ets.lookup(ets_table, cache_key) do
      # Cache Hit
      [{^cache_key, value, expiry_ts, stale_serve_until_ts}] ->
        handle_cache_hit_and_proceed(
          conn,
          log_prefix,
          value,
          expiry_ts,
          stale_serve_until_ts,
          opts,
          extracted_data,
          cache_key
        )

      # Cache Miss
      [] ->
        Logger.debug("#{log_prefix} Cache Miss. Fetching synchronously.")
        # Perform initial synchronous fetch
        handle_sync_fetch_and_proceed(conn, log_prefix, opts, extracted_data, cache_key)
    end
  end

  # --- Default Implementation Functions (Public visibility required for Plug init) ---

  @doc """
  Default function for extracting data. Returns an empty map.
  """
  def default_extract_data(_conn), do: %{}

  @doc """
  Default function for generating a cache key. Returns a fixed atom.
  """
  def default_cache_key(_conn), do: :isr_plug_default_key

  @doc """
  Default error handler if synchronous fetch fails. Logs and passes conn through.
  """
  def default_error_handler(conn, reason) do
    log_prefix = "[#{__MODULE__}][DefaultErrorHandler]"

    Logger.error(
      "#{log_prefix} Synchronous fetch failed: #{inspect(reason)}. Passing connection through unchanged."
    )

    conn
  end

  # --- Private Processing Logic ---

  # Handles the logic when an item is found in the cache
  defp handle_cache_hit_and_proceed(
         conn,
         log_prefix,
         value,
         expiry_ts,
         stale_serve_until_ts,
         opts,
         extracted_data,
         cache_key
       ) do
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
        # Pass necessary opts explicitly to the background task
        ets_table = opts[:ets_table]
        fetch_fun = opts[:fetch_fun]
        cache_ttl_ms = opts[:cache_ttl_ms]
        stale_ttl_ms = opts[:stale_serving_ttl_ms]

        Task.start(fn ->
          perform_background_refresh(
            log_prefix,
            ets_table,
            fetch_fun,
            cache_ttl_ms,
            stale_ttl_ms,
            extracted_data,
            cache_key
          )
        end)

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
    # Extract necessary options
    ets_table = opts[:ets_table]
    fetch_fun = opts[:fetch_fun]
    cache_ttl_ms = opts[:cache_ttl_ms]
    stale_ttl_ms = opts[:stale_serving_ttl_ms]
    error_handler_fun = opts[:error_handler_fun]
    apply_fun = opts[:apply_fun]

    case fetch_synchronously_and_cache(
           log_prefix,
           ets_table,
           cache_key,
           fetch_fun,
           extracted_data,
           cache_ttl_ms,
           stale_ttl_ms
         ) do
      {:ok, value} ->
        # Fetched successfully, apply the new value
        apply_value(conn, value, apply_fun)

      {:error, reason} ->
        # Sync fetch failed, call the configured error handler
        Logger.error("#{log_prefix} Synchronous fetch failed: #{inspect(reason)}")
        error_handler_fun.(conn, reason)
    end
  end

  # Applies the value using the configured apply_fun, handling nil values
  defp apply_value(conn, value, apply_fun) do
    if not is_nil(value) do
      apply_fun.(conn, value)
    else
      # This case might happen if fetch failed and error handler didn't halt/change conn
      Logger.warning(
        "[#{__MODULE__}] No value available to apply (sync fetch likely failed and error handler didn't halt). Passing conn through."
      )

      conn
    end
  end

  # --- Private Fetching & Caching Helpers ---

  # Performs a synchronous fetch and updates the cache on success
  defp fetch_synchronously_and_cache(
         log_prefix,
         ets_table,
         cache_key,
         fetch_fun,
         extracted_data,
         cache_ttl_ms,
         stale_ttl_ms
       ) do
    Logger.debug("#{log_prefix} Fetching synchronously...")

    case fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
      {:ok, value} ->
        update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms)
        {:ok, value}

      {:error, reason} ->
        # Error already logged by fetch_dynamic_value if needed
        {:error, reason}
    end
  end

  # Performs an asynchronous fetch and updates the cache (called via Task.start)
  defp perform_background_refresh(
         log_prefix,
         ets_table,
         fetch_fun,
         cache_ttl_ms,
         stale_ttl_ms,
         extracted_data,
         cache_key
       ) do
    Logger.debug("#{log_prefix} Performing background refresh...")

    case fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
      {:ok, value} ->
        update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms)
        Logger.debug("#{log_prefix} Background refresh successful.")

      {:error, reason} ->
        # Log the error here as the caller task won't report it directly
        Logger.error("#{log_prefix} Background refresh failed: #{inspect(reason)}")
        # Optionally: Implement retry or backoff logic here
    end

    # Task completes
    :ok
  end

  # Safely executes the user-provided fetch_fun
  defp fetch_dynamic_value(log_prefix, fetch_fun, extracted_data) do
    try do
      case fetch_fun.(extracted_data) do
        {:ok, value} ->
          {:ok, value}

        {:error, reason} ->
          # Propagate known fetch errors
          {:error, reason}

        other ->
          # Handle cases where fetch_fun doesn't return the expected tuple
          Logger.warning(
            "#{log_prefix} Fetch function returned unexpected value: #{inspect(other)}. Expected {:ok, value} or {:error, reason}. Treating as error."
          )

          {:error, {:unexpected_return, other}}
      end
    rescue
      # Catch any exceptions during fetch_fun execution
      e ->
        err = Exception.format(:error, e, __STACKTRACE__)
        Logger.error("#{log_prefix} Unhandled exception during fetch_fun execution: #{err}")
        # Return exception as error reason
        {:error, {:exception, e}}
    end
  end

  # Updates the ETS cache with the new value and calculated timestamps
  defp update_cache(log_prefix, ets_table, cache_key, value, cache_ttl_ms, stale_ttl_ms) do
    now = System.monotonic_time()
    # Calculate expiry timestamp based on monotonic time + TTL
    expiry_ts = now + System.convert_time_unit(cache_ttl_ms, :millisecond, :native)

    # Calculate when stale serving should stop (expiry + stale TTL)
    stale_serve_until_ts =
      expiry_ts + System.convert_time_unit(stale_ttl_ms, :millisecond, :native)

    # Insert/update the cache entry
    :ets.insert(ets_table, {cache_key, value, expiry_ts, stale_serve_until_ts})
    Logger.debug("#{log_prefix} Updated cache.")
  end

  # --- Private Validation Helper ---

  # Helper for init options validation (ensures functions have correct arity)
  defp validate_fun!(opts, key, arity, signature) do
    fun = Keyword.get(opts, key)

    # Ensure the key exists and holds a function of the specified arity
    unless is_function(fun, arity) do
      # Raise a more informative error if the key is missing or not a function
      cond do
        is_nil(fun) ->
          raise ArgumentError, "Required option :#{key} is missing."

        not is_function(fun) ->
          raise ArgumentError, "Option :#{key} (value: #{inspect(fun)}) must be a function."

        true ->
          # Arity mismatch
          raise ArgumentError,
                "Option :#{key} must be a function with arity #{arity} #{signature}, got function with arity #{Function.info(fun)[:arity]}."
      end
    end
  end
end
