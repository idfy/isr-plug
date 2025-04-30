# ISRPlug

[![Hex.pm](https://img.shields.io/hexpm/v/isr_plug.svg)](https://hex.pm/packages/isr_plug)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/isr_plug/)

`ISRPlug` is a generic, reusable Elixir Plug designed to implement the Incremental Static Regeneration (ISR) pattern within Phoenix (or other Plug-based) applications.

It helps improve performance and maintain data freshness by:

*   Serving cached data (fresh or slightly stale) quickly using an ETS table.
*   Triggering non-blocking background tasks to refresh expired data.
*   Allowing flexible, application-specific logic for fetching data and applying it to the `Plug.Conn`.

## Problem Addressed

Web applications often need dynamic data (e.g., configuration, feature flags, content) per request. Fetching this synchronously can slow down responses. Standard caching helps but can lead to serving stale data indefinitely or requiring complex invalidation.

ISR offers a balance: serve stale data for a limited time while refreshing in the background, ensuring eventual consistency without blocking the user request.

## Installation

Add `isr_plug` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:isr_plug, "~> 0.1.1"} # Check Hex.pm for the latest version
    # Or use path: {:isr_plug, path: "../path/to/isr_plug"} for local dev
    # Or git: {:isr_plug, git: "https://github.com/your_github_username/isr_plug.git", tag: "v0.1.1"}
  ]
end
```

Then, run `mix deps.get`.

## Setup: ETS Cache Initialization

`ISRPlug` relies on an ETS table for caching. This table needs to exist when your application starts. The recommended way to manage this is using the included `ISRPlug.CacheManager` GenServer.

1.  **Ensure `ISRPlug.CacheManager` Exists:** If you installed `isr_plug` as a Hex dependency, the `ISRPlug.CacheManager` module is included. If you are using it via a path or copied the code, ensure the `lib/isr_plug/cache_manager.ex` file is present in your project or the dependency path.

2.  **Add `CacheManager` to Your Application Supervisor:** Edit your main application file (e.g., `lib/my_app/application.ex`) and add `ISRPlug.CacheManager` to the list of children started by your supervisor.

    ```elixir
    # lib/my_app/application.ex
    defmodule MyApp.Application do
      use Application
      require Logger

      @impl true
      def start(_type, _args) do
        children = [
          # ... other children like Repo, Endpoint, PubSub ...
          MyApp.Repo,
          MyAppWeb.Endpoint,

          # Add the ISRPlug Cache Manager HERE
          # This will create the default :isr_plug_cache ETS table on startup.
          ISRPlug.CacheManager

          # --- OR ---

          # If you need different/multiple ETS tables for ISRPlug:
          # {ISRPlug.CacheManager, table_names: [:my_isr_cache, :another_isr_cache]}

          # --- OR ---

          # If you need a specific name for the manager process itself (rare):
          # {ISRPlug.CacheManager, name: MyApp.ISRCacheSupervisor}

        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

      # ... config_change etc. ...
    end
    ```

    This ensures that the necessary ETS table(s) are created when your application boots and are available for the plug to use.

## Usage

With the setup complete, you can now use the plug in your application pipelines.

1.  **Define Your Logic Module:** Create a module in your application containing the functions needed by the plug.

    ```elixir
    # lib/my_app/dynamic_config.ex
    defmodule MyApp.DynamicConfig do
      require Logger

      # --- FETCH FUNCTION ---
      # Fetches the data. Receives data extracted by `extract_data_fun`.
      # Must return {:ok, value} or {:error, reason}.
      def fetch_settings(extracted_data) do
        tenant_id = extracted_data[:tenant_id]
        Logger.info("Fetching settings for tenant: #{tenant_id}")
        # Simulate fetching from DB or API
        # In a real app, handle potential errors here
        case :rand.uniform(5) do
          1 -> {:error, :simulated_fetch_error}
          _ ->
            settings = %{feature_x_enabled: true, theme: "dark", ts: :os.system_time(:millisecond)} # Example data
            {:ok, settings}
        end
      end

      # --- APPLY FUNCTION ---
      # Applies the fetched data to the connection.
      # Receives the conn and the fetched value. Must return the conn.
      def apply_settings(conn, settings) do
        Plug.Conn.assign(conn, :dynamic_settings, settings)
      end

      # --- (Optional) EXTRACT DATA FUNCTION ---
      # Extracts data needed for fetching from the conn.
      # Defaults to fn _ -> %{} end provided by ISRPlug.default_extract_data/1
      def extract_tenant_id(conn) do
         # Example: Get tenant from subdomain or session
         %{tenant_id: conn.host |> String.split(".") |> List.first("default")}
      end

      # --- (Optional) CACHE KEY FUNCTION ---
      # Generates a unique cache key based on the conn.
      # Defaults to fn _ -> :isr_plug_default_key end provided by ISRPlug.default_cache_key/1
      # IMPORTANT: Use if fetched data varies per request context (user, tenant, etc.)
      def settings_cache_key(conn) do
        tenant_id = conn.host |> String.split(".") |> List.first("default")
        {:settings, tenant_id} # Example: Tuple key based on data type and tenant
      end

      # --- (Optional) ERROR HANDLER FUNCTION ---
      # Handles errors during *synchronous* fetches (cache miss/expired stale).
      # Receives conn and the error reason. Must return the conn.
      # Default logs the error and returns the conn unchanged (ISRPlug.default_error_handler/2)
      def handle_fetch_error(conn, reason) do
        tenant_id = conn.host |> String.split(".") |> List.first("default")
        Logger.error("[DynamicConfig] Failed to fetch settings for #{tenant_id}: #{inspect reason}. Assigning defaults.")
        # Example: Assign default settings or halt
        Plug.Conn.assign(conn, :dynamic_settings, %{feature_x_enabled: false, theme: "light", error: reason})
        # Or halt the connection:
        # conn |> Plug.Conn.send_resp(:internal_server_error, "Config error") |> Plug.Conn.halt()
      end
    end
    ```

2.  **Add the Plug to Your Pipeline:** In your `router.ex` or `endpoint.ex`, add `plug ISRPlug` with your configuration.

    ```elixir
    # lib/my_app_web/router.ex
    defmodule MyAppWeb.Router do
      use MyAppWeb, :router
      # No need to import ISRPlug if using explicit module calls
      alias MyApp.DynamicConfig

      pipeline :browser do
        plug :accepts, ["html"]
        # ... other plugs: fetch_session, fetch_live_flash, etc. ...

        # Add ISRPlug to fetch dynamic settings
        plug ISRPlug,
          # Required functions
          fetch_fun: &DynamicConfig.fetch_settings/1,
          apply_fun: &DynamicConfig.apply_settings/2,

          # Optional functions (use defaults if omitted)
          extract_data_fun: &DynamicConfig.extract_tenant_id/1,
          cache_key_fun: &DynamicConfig.settings_cache_key/1,
          error_handler_fun: &DynamicConfig.handle_fetch_error/2,

          # Optional configuration
          # IMPORTANT: `:ets_table` MUST match a table managed by ISRPlug.CacheManager
          ets_table: :isr_plug_cache,          # Use the default table name
          cache_ttl_ms: :timer.seconds(30),    # Data is fresh for 30 seconds
          stale_serving_ttl_ms: :timer.minutes(5) # Serve stale for 5 min while refreshing

        # ... other plugs ...
        plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
      end

      scope "/", MyAppWeb do
        pipe_through :browser # Use the pipeline where ISRPlug is configured

        get "/", PageController, :home # Example route using the pipeline
      end
    end
    ```

## Configuration Options (for `plug ISRPlug, ...`)

See `ISRPlug.init/1` documentation for details on all options:

*   `:fetch_fun` (**required**): `(extracted_data :: any()) -> {:ok, value :: any()} | {:error, reason :: any()}`
*   `:apply_fun` (**required**): `(conn :: Plug.Conn.t(), value :: any()) -> Plug.Conn.t()`
*   `:extract_data_fun` (*optional*, defaults to `&ISRPlug.default_extract_data/1`): `(conn :: Plug.Conn.t()) -> any()`
*   `:cache_key_fun` (*optional*, defaults to `&ISRPlug.default_cache_key/1`): `(conn :: Plug.Conn.t()) -> term()`
*   `:ets_table` (*optional*, defaults to `:isr_plug_cache`): `atom()`. Must match a table name configured in `ISRPlug.CacheManager`.
*   `:cache_ttl_ms` (*optional*, defaults to 60_000 ms): `non_neg_integer()`
*   `:stale_serving_ttl_ms` (*optional*, defaults to 3_600_000 ms): `non_neg_integer()`
*   `:error_handler_fun` (*optional*, defaults to `&ISRPlug.default_error_handler/2`): `(conn :: Plug.Conn.t(), reason :: any()) -> Plug.Conn.t()`

## How it Works

1.  On request, `extract_data_fun` runs, then `cache_key_fun` determines the ETS cache key.
2.  The ETS table (specified by `:ets_table`, created by `ISRPlug.CacheManager`) is checked for the key.
3.  **Cache Hit (Fresh):** If data exists and its timestamp is within `cache_ttl_ms`, `apply_fun` runs with the cached value.
4.  **Cache Hit (Stale):** If data exists, its timestamp is older than `cache_ttl_ms`, but *newer* than `cache_ttl_ms + stale_serving_ttl_ms`, `apply_fun` runs with the *stale* cached value, AND a non-blocking `Task` starts in the background to call `fetch_fun` and update the cache.
5.  **Cache Miss / Too Stale:** If no data exists, or its timestamp is older than `cache_ttl_ms + stale_serving_ttl_ms`, `fetch_fun` runs *synchronously* in the current request process.
    *   **Success:** The result is cached, and `apply_fun` runs with the new value.
    *   **Failure:** `error_handler_fun` runs. The default handler logs the error and passes the connection through; `apply_fun` is *not* called unless the error handler modifies the `conn` in a way that implies success or provides default data.
6.  The potentially modified connection is passed to the next plug.

## Testing the Plug

### Running Library Unit Tests

If you have cloned the `isr_plug` repository itself:

```bash
mix deps.get
mix test
```

### Testing Integration in Your Application (Development)

1.  **Ensure Setup:** Make sure you have followed the [Setup](#setup-ets-cache-initialization) steps to add `ISRPlug.CacheManager` to your application's supervisor in the `test` environment as well (usually handled by `application.ex` unless you have complex test setup).
2.  **Add as Path Dependency (Optional):** If developing `isr_plug` locally, use a path dependency in your *consuming application's* `mix.exs`:

    ```elixir
    # In your Phoenix app's mix.exs
    def deps do
      [
        # ... other deps
        {:isr_plug, path: "/path/to/your/local/isr_plug"}
      ]
    end
    ```
    Run `mix deps.get` in your consuming application.

3.  **Configure the Plug:** Add the plug to your router or endpoint as shown in the [Usage](#usage) section. Use short TTLs (`cache_ttl_ms`, `stale_serving_ttl_ms`) in the `:test` environment config if you need to test expiration behaviour quickly.
4.  **Observe Logs:** Start your Phoenix server (`mix phx.server`). Make requests to the relevant endpoints. Check your application logs for messages from `[ISRPlug]` indicating cache hits (fresh/stale), misses, synchronous fetches, and background refreshes. Look for the specific `ets_table` and `cache_key` in the log prefix.
5.  **Verify Behavior:**
    *   Check if the data applied by your `apply_fun` (e.g., assigns, headers) is present in the `conn` or response using browser tools or test assertions.
    *   Modify the underlying data source that your `fetch_fun` uses. Observe if the application picks up the change after the `cache_ttl_ms` duration (on the next request after that period), serving stale data in between (if `stale_serving_ttl_ms` allows). A fully expired item (older than `cache_ttl_ms + stale_serving_ttl_ms`) should trigger a synchronous fetch immediately.
    *   Simulate errors in your `fetch_fun` and verify that your `error_handler_fun` is called correctly during synchronous fetches (cache misses or expired stale items).

## Concurrency Considerations and Limitations (ETS Locking)

The current implementation of `ISRPlug` uses ETS for caching. When stale data is encountered, it triggers a background `Task` to refresh the data.

**Potential Issue: Concurrent Background Refreshes**

Phoenix handles requests using multiple concurrent processes. ETS provides shared memory on a single node. There's a subtle **race condition** specifically related to triggering the **background refresh task**:

1.  **Request A (Process A):** Checks the cache, finds stale data, decides a background refresh is needed.
2.  **Request B (Process B):** *Almost simultaneously*, checks the cache, finds the *same* stale data, and *also* decides a background refresh is needed.
3.  **Outcome:** Both Process A and Process B might independently start a background `Task` to execute your `:fetch_fun` before either task has had a chance to update the cache.

This can lead to:

*   **Redundant Work:** Your potentially expensive `:fetch_fun` (DB query, API call) runs multiple times when only one refresh was necessary.
*   **Resource Spikes:** More temporary processes (`Task`s) are created than needed.
*   **Downstream Pressure:** Increased load on databases or external APIs, potentially hitting rate limits.

**Why This Happens (ETS vs. Serialized Logic):**

*   Each request runs in its own process.
*   The sequence "Check Cache -> Decide Refresh -> Start Task" is performed independently by each process.
*   There's no mechanism *inherent in this Plug's ETS-based approach* to guarantee that only *one* process "wins" the right to start the background task during that tiny window.

**Why Locking is NOT Applied to Synchronous Fetches:**

The plug **intentionally does not** attempt to prevent concurrent *synchronous* fetches (when data is missing entirely or too stale). Applying a lock here would mean requests could be blocked waiting for *other* requests to finish fetching the same missing data, significantly slowing down responses during cache misses. Allowing concurrent synchronous fetches ensures requests aren't blocked, and the first one to finish populates the cache.

**Alternative (More Complex) Solution: GenServer Coordinator**

A more robust way to guarantee only one background refresh task runs at a time (on a single node) involves using a central coordinating process (e.g., a `GenServer`) to manage refresh state. When the plug detects stale data, it would message the coordinator, which would then decide whether to start a *new* task or ignore the request if a refresh is already in progress for that key.

**Why We Didn't Implement the GenServer:**

*   **Increased Complexity:** Requires adding and managing another dedicated process within your application's supervision tree.
*   **Potential Bottleneck:** The single GenServer becomes a serialization point for *all* background refresh triggers.
*   **Simplicity Trade-off:** The current `ISRPlug` implementation prioritizes simplicity and accepts the possibility of occasional redundant *background* refresh tasks. This is often an acceptable trade-off.

If absolute prevention of concurrent background refreshes is critical, consider implementing a custom solution using the GenServer coordinator pattern.

## Contributing

Contributions are welcome! Please open an issue to discuss potential changes or submit a pull request with tests.

## License

This project is licensed under the Apache 2.0 License.