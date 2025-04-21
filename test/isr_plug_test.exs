defmodule ISRPlugTest do
  use ExUnit.Case, async: false # Keep async: false
  import Plug.Test

  alias ISRPlug

  # Use compile_env for better practice and provide a default
  @test_ets_table Application.compile_env(:isr_plug, :test_ets_table, :isr_plug_test_table)

  # --- Test Configuration ---
  defp default_opts(overrides \\ []) do
    Keyword.merge([
      fetch_fun: &fetch_success/1,
      apply_fun: &apply_assigns/2,
      ets_table: @test_ets_table,
      cache_ttl_ms: 100, # Short TTL for testing
      stale_serving_ttl_ms: 200 # Short stale TTL for testing
    ], overrides)
  end

  # --- Mock Functions ---
  def fetch_success(_extracted_data), do: {:ok, "fetched_value"}
  def fetch_error(_extracted_data), do: {:error, :fetch_failed}
  def fetch_slow(_extracted_data) do
    Process.sleep(50) # Simulate some work
    {:ok, "fetched_slow_value"}
  end

  def apply_assigns(conn, value), do: Plug.Conn.assign(conn, :isr_data, value)
  def apply_header(conn, value), do: Plug.Conn.put_resp_header(conn, "x-isr-data", value)

  def extract_host(conn), do: %{host: conn.host}
  def cache_key_host(conn), do: {:host, conn.host}
  def cache_key_static(_conn), do: :static_key

  def error_handler_halt(conn, _reason), do: Plug.Conn.assign(conn, :error_handled, true) |> Plug.Conn.halt()
  def error_handler_assign(conn, reason), do: Plug.Conn.assign(conn, :fetch_error, reason)

  # --- Setup ---
  setup do
    # Create table if it doesn't exist
    if :ets.info(@test_ets_table) == :undefined do
      :ets.new(@test_ets_table, [:named_table, :set, :public])
    else
      # Clean existing table
      :ets.delete_all_objects(@test_ets_table)
    end
    :ok
  end

  # --- Tests ---

  test "init raises error if required options are missing" do
    assert_raise KeyError, fn ->
      ISRPlug.init([])
    end
    assert_raise KeyError, fn ->
      ISRPlug.init(fetch_fun: &fetch_success/1)
    end
  end

  test "init raises error if function arity is wrong" do
     assert_raise ArgumentError, ~r/arity 1/, fn ->
       ISRPlug.init(fetch_fun: fn -> :ok end, apply_fun: &apply_assigns/2)
     end
     assert_raise ArgumentError, ~r/arity 2/, fn ->
       ISRPlug.init(fetch_fun: &fetch_success/1, apply_fun: fn _ -> :ok end)
     end
  end

  test "init creates ETS table if it doesn't exist" do
    # Use a unique atom for the table name, not a ref
    table_name = :"test_table_#{System.unique_integer([:positive])}"
    opts = default_opts(ets_table: table_name) # Use unique table name
    assert :ets.info(table_name, :name) == :undefined
    # Init should return the processed opts, but we only care about the side effect here
    _ = ISRPlug.init(opts)
    assert :ets.info(table_name, :name) == table_name
    :ets.delete(table_name) # Clean up
  end

  test "call with cache miss performs synchronous fetch and applies data" do
    opts = default_opts()
    initialized_opts = ISRPlug.init(opts) # Initialize opts first
    conn = conn(:get, "/") |> ISRPlug.call(initialized_opts)

    assert conn.assigns[:isr_data] == "fetched_value"
    assert :ets.lookup(@test_ets_table, :isr_plug_default_key) != [] # Check cache populated
  end

   test "call with cache miss and fetch error calls error handler" do
    opts = default_opts(fetch_fun: &fetch_error/1, error_handler_fun: &error_handler_assign/2)
    initialized_opts = ISRPlug.init(opts) # Initialize opts first
    conn = conn(:get, "/") |> ISRPlug.call(initialized_opts)

    assert conn.assigns[:fetch_error] == :fetch_failed
    assert conn.assigns[:isr_data] == nil # Apply fun should not be called
    assert :ets.lookup(@test_ets_table, :isr_plug_default_key) == [] # Cache should not be populated on error
  end

  test "call with cache miss and fetch error halts if error handler halts" do
    opts = default_opts(fetch_fun: &fetch_error/1, error_handler_fun: &error_handler_halt/2)
    initialized_opts = ISRPlug.init(opts) # Initialize opts first
    conn = conn(:get, "/") |> ISRPlug.call(initialized_opts)

    assert conn.assigns[:error_handled] == true
    assert conn.halted
  end

  test "call with fresh cache hit serves cached data" do
    opts = default_opts()
    initialized_opts = ISRPlug.init(opts) # Initialize opts first
    # Prime cache
    conn(:get, "/") |> ISRPlug.call(initialized_opts)
    assert :ets.lookup(@test_ets_table, :isr_plug_default_key) != []

    # Second call should hit cache
    conn = conn(:get, "/")
           |> Map.put(:assigns, %{}) # Clear assigns
           |> ISRPlug.call(initialized_opts) # Use initialized opts

    assert conn.assigns[:isr_data] == "fetched_value" # Served from cache
  end

  test "call with stale cache hit serves stale data and triggers background refresh" do
    opts = default_opts(fetch_fun: &fetch_slow/1, cache_ttl_ms: 50, stale_serving_ttl_ms: 500)
    initialized_opts = ISRPlug.init(opts) # Initialize opts first
    # 1. Prime cache
    conn_prime = conn(:get, "/") |> ISRPlug.call(initialized_opts)
    assert conn_prime.assigns[:isr_data] == "fetched_slow_value"
    [{_key, value, _exp, _stale_exp}] = :ets.lookup(@test_ets_table, :isr_plug_default_key)
    assert value == "fetched_slow_value"

    # 2. Wait for cache to expire but still be in stale window
    Process.sleep(100) # Wait > cache_ttl_ms (50ms) but < stale_ttl (50ms + 500ms)

    # 3. Call again - should serve stale and trigger background task
    # Mock Task.start to verify it's called (tricky without mocking library)
    # Instead, we'll check the side effect: cache eventually updates
    conn_stale = conn(:get, "/")
                 |> Map.put(:assigns, %{}) # Clear assigns
                 |> ISRPlug.call(initialized_opts) # Use initialized opts

    # Assert served stale value immediately
    assert conn_stale.assigns[:isr_data] == "fetched_slow_value"

    # 4. Wait for background task to likely complete (fetch_slow takes 50ms)
    Process.sleep(100)

    # 5. Check if cache was updated by background task
    [{_key, new_value, _exp_new, _stale_exp_new}] = :ets.lookup(@test_ets_table, :isr_plug_default_key)
    # Assert background fetch ran and updated cache (value should still be the same in this test case)
    assert new_value == "fetched_slow_value" # fetch_slow returns this

    # Clear the table before the next section of the test
    :ets.delete_all_objects(@test_ets_table)

    # --- Refined Stale Cache Test ---
    fetch_counter = :atomics.new(1, [])
    dynamic_fetch = fn _ ->
      # add_get increments *before* returning. Start at 1 -> first call returns 1.
      count = :atomics.add_get(fetch_counter, 1, 1)
      Process.sleep(50)
      {:ok, "fetched_value_#{count}"}
    end

    opts_dynamic = default_opts(fetch_fun: dynamic_fetch, cache_ttl_ms: 50, stale_serving_ttl_ms: 500)
    initialized_opts_dynamic = ISRPlug.init(opts_dynamic) # Initialize dynamic opts

    # 1. Prime cache (fetch count becomes 1)
    conn_prime_dyn = conn(:get, "/") |> ISRPlug.call(initialized_opts_dynamic)
    assert conn_prime_dyn.assigns[:isr_data] == "fetched_value_1" # Expect 1
    [{_, val1, _, _}] = :ets.lookup(@test_ets_table, :isr_plug_default_key)
    assert val1 == "fetched_value_1" # Expect 1

    # 2. Wait for stale
    Process.sleep(100)

    # 3. Call again (serves stale "fetched_value_1", triggers background fetch which increments count to 2)
    conn_stale_dyn = conn(:get, "/") |> Map.put(:assigns, %{}) |> ISRPlug.call(initialized_opts_dynamic)
    assert conn_stale_dyn.assigns[:isr_data] == "fetched_value_1" # Served stale 1

    # 4. Wait for background task
    Process.sleep(100)

    # 5. Check cache updated by background task
    [{_, val2, _, _}] = :ets.lookup(@test_ets_table, :isr_plug_default_key)
    assert val2 == "fetched_value_2" # Cache updated to 2

    # 6. Call again (should now be fresh hit with value 2)
    conn_fresh_dyn = conn(:get, "/") |> Map.put(:assigns, %{}) |> ISRPlug.call(initialized_opts_dynamic)
    assert conn_fresh_dyn.assigns[:isr_data] == "fetched_value_2" # Fresh hit 2

    # --- End Refined Stale Cache Test ---

  end

  test "call with expired stale TTL performs synchronous fetch" do
     opts = default_opts(cache_ttl_ms: 50, stale_serving_ttl_ms: 50) # Very short stale window
     initialized_opts = ISRPlug.init(opts) # Initialize base opts
     # 1. Prime cache
     conn(:get, "/") |> ISRPlug.call(initialized_opts)

     # 2. Wait for cache AND stale TTL to expire
     Process.sleep(150) # Wait > cache_ttl (50) + stale_ttl (50)

     # 3. Call again - should trigger synchronous fetch
     fetch_counter = :atomics.new(1, [])
     dynamic_fetch = fn _ -> {:ok, "sync_fetch_#{:atomics.add_get(fetch_counter, 1, 1)}"} end
     opts_sync = Keyword.put(opts, :fetch_fun, dynamic_fetch)
     initialized_opts_sync = ISRPlug.init(opts_sync) # Initialize sync opts

     # This is the first call with dynamic_fetch, counter increments to 1
     conn_sync = conn(:get, "/")
                 |> Map.put(:assigns, %{}) # Clear assigns
                 |> ISRPlug.call(initialized_opts_sync) # Pass initialized sync opts

     # Assert served newly fetched value (count is 1)
     assert conn_sync.assigns[:isr_data] == "sync_fetch_1" # Expect 1
     [{_, val, _, _}] = :ets.lookup(@test_ets_table, :isr_plug_default_key)
     assert val == "sync_fetch_1" # Cache updated synchronously with 1
  end

  test "uses extract_data_fun and cache_key_fun correctly" do
    # Define expected extracted data based on the host we will set
    expected_host = "example.com"
    extracted = %{host: expected_host}
    key = {:host, expected_host}

    # Mock fetch_fun to assert extracted_data
    mock_fetch = fn data ->
      # Assert that the data passed to fetch_fun matches what extract_data_fun should produce
      assert data == extracted
      {:ok, "data_for_#{data[:host]}"}
    end

    opts = default_opts(
      extract_data_fun: &extract_host/1,
      cache_key_fun: &cache_key_host/1,
      fetch_fun: mock_fetch
    )
    initialized_opts = ISRPlug.init(opts) # Initialize opts

    # Set host directly on the conn struct
    conn = conn(:get, "/")
           |> Map.put(:host, expected_host)
           |> ISRPlug.call(initialized_opts)

    # Assert that apply_fun was called correctly
    assert conn.assigns[:isr_data] == "data_for_#{expected_host}"
    # Assert that the cache was populated with the correct key
    assert :ets.lookup(@test_ets_table, key) != [] # Check cache uses correct key
  end

end
