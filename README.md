# ISRPlug

[![Hex.pm](https://img.shields.io/hexpm/v/isr_plug.svg)](https://hex.pm/packages/isr_plug)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/isr_plug/)

`ISRPlug` is a generic, reusable Elixir Plug designed to implement the Incremental Static Regeneration (ISR) pattern within Phoenix (or other Plug-based) applications.

It helps improve performance and maintain data freshness by:

*   Serving cached data (fresh or slightly stale) quickly.
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
    {:isr_plug, "~> 0.1.0"} # Or use path: {:isr_plug, path: "../path/to/isr_plug"} for local dev
    # Or git: {:isr_plug, git: "https://github.com/your_github_username/isr_plug.git", tag: "v0.1.0"}
  ]
end
```

Then, run `mix deps.get`.

## Usage

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
        settings = %{feature_x_enabled: true, theme: "dark"} # Example data
        {:ok, settings}
        # Or: {:error, :database_timeout}
      end

      # --- APPLY FUNCTION ---
      # Applies the fetched data to the connection.
      # Receives the conn and the fetched value. Must return the conn.
      def apply_settings(conn, settings) do
        Plug.Conn.assign(conn, :dynamic_settings, settings)
      end

      # --- (Optional) EXTRACT DATA FUNCTION ---
      # Extracts data needed for fetching from the conn.
      # Defaults to fn _ -> %{} end.
      def extract_tenant_id(conn) do
         # Example: Get tenant from subdomain or session
         %{tenant_id: conn.host |> String.split(".") |> List.first()}
      end

      # --- (Optional) CACHE KEY FUNCTION ---
      # Generates a unique cache key based on the conn.
      # Defaults to fn _ -> :isr_plug_default_key end.
      # IMPORTANT: Use if fetched data varies per request context (user, tenant, etc.)
      def settings_cache_key(conn) do
        tenant_id = conn.host |> String.split(".") |> List.first()
        {:settings, tenant_id}
      end

      # --- (Optional) ERROR HANDLER FUNCTION ---
      # Handles errors during *synchronous* fetches (cache miss/expired stale).
      # Receives conn and the error reason. Must return the conn.
      # Default logs the error and returns the conn unchanged.
      def handle_fetch_error(conn, reason) do
        Logger.error("Failed to fetch dynamic settings: #{inspect reason}. Assigning defaults.")
        # Example: Assign default settings or halt
        Plug.Conn.assign(conn, :dynamic_settings, %{feature_x_enabled: false, theme: "light"})
        # Or: conn |> Plug.Conn.send_resp(:internal_server_error, "Config error") |> Plug.Conn.halt()
      end
    end
    ```

2.  **Add the Plug to Your Pipeline:** In your `router.ex` or `endpoint.ex`, add `ISRPlug` with your configuration.

    ```elixir
    # lib/my_app_web/router.ex
    defmodule MyAppWeb.Router do
      use MyAppWeb, :router
      import ISRPlug # Import to use `plug ISRPlug` directly
      alias MyApp.DynamicConfig

      pipeline :browser do
        plug :accepts, ["html"]
        # ... other plugs ...

        # Add ISRPlug to fetch dynamic settings
        plug ISRPlug,
          fetch_fun: &DynamicConfig.fetch_settings/1,
          apply_fun: &DynamicConfig.apply_settings/2,
          # Optional functions:
          extract_data_fun: &DynamicConfig.extract_tenant_id/1,
          cache_key_fun: &DynamicConfig.settings_cache_key/1,
          error_handler_fun: &DynamicConfig.handle_fetch_error/2,
          # Optional configuration:
          ets_table: :dynamic_settings_cache, # Use a specific ETS table name
          cache_ttl_ms: :timer.minutes(5),    # Data is fresh for 5 minutes
          stale_serving_ttl_ms: :timer.hours(1) # Serve stale for 1 hour while refreshing

        # ... other plugs ...
      end

      scope "/", MyAppWeb do
        pipe_through :browser
        get "/", PageController, :index
      end
    end
    ```

## Configuration Options

See `ISRPlug.init/1` documentation for details on all options:

*   `:fetch_fun` (**required**)
*   `:apply_fun` (**required**)
*   `:extract_data_fun` (*optional*)
*   `:cache_key_fun` (*optional*)
*   `:ets_table` (*optional*, defaults to `:isr_plug_cache`)
*   `:cache_ttl_ms` (*optional*, defaults to 1 minute)
*   `:stale_serving_ttl_ms` (*optional*, defaults to 1 hour)
*   `:error_handler_fun` (*optional*)

## How it Works

1.  On request, `extract_data_fun` runs, then `cache_key_fun` determines the ETS cache key.
2.  The ETS table (`:ets_table`) is checked for the key.
3.  **Cache Hit (Fresh):** If data exists and hasn't passed `cache_ttl_ms`, `apply_fun` runs with the cached value.
4.  **Cache Hit (Stale):** If data exists, passed `cache_ttl_ms`, but *not* `stale_serving_ttl_ms`, `apply_fun` runs with the *stale* cached value, AND a non-blocking `Task` starts in the background to call `fetch_fun` and update the cache.
5.  **Cache Miss / Too Stale:** If no data exists, or it passed `stale_serving_ttl_ms`, `fetch_fun` runs *synchronously*.
    *   **Success:** The result is cached, and `apply_fun` runs with the new value.
    *   **Failure:** `error_handler_fun` runs. The default handler logs the error and passes the connection through; `apply_fun` is *not* called.
6.  The potentially modified connection is passed to the next plug.

## Testing the Plug

### Running Unit Tests

The library includes unit tests. Clone the repository and run:

```bash
mix deps.get
mix test
```

### Testing Integration in Your Application (Development)

1.  **Add as Path Dependency:** In your *consuming application's* `mix.exs`, add `isr_plug` using a path dependency:

    ```elixir
    # In your Phoenix app's mix.exs
    def deps do
      [
        # ... other deps
        {:isr_plug, path: "../path/to/your/local/isr_plug/checkout"}
      ]
    end
    ```

2.  **Run `mix deps.get`** in your consuming application.
3.  **Configure the Plug:** Add the plug to your router or endpoint as shown in the [Usage](#usage) section.
4.  **Observe Logs:** Start your Phoenix server (`mix phx.server`). Make requests to the relevant endpoints. Check your application logs for messages from `[ISRPlug]` indicating cache hits (fresh/stale), misses, synchronous fetches, and background refreshes.
5.  **Verify Behavior:**
    *   Check if the data applied by your `apply_fun` (e.g., assigns, headers) is present in the `conn` or response.
    *   Modify the underlying data source that your `fetch_fun` uses. Observe if the application picks up the change after the `cache_ttl_ms` + `stale_serving_ttl_ms` duration (on the next request after that period), or sooner if a background refresh completes after the `cache_ttl_ms`.
    *   Simulate errors in your `fetch_fun` and verify that your `error_handler_fun` is called correctly during synchronous fetches.

## Concurrency Considerations and Limitations (ETS Locking)

The current implementation of `ISRPlug` uses ETS for caching. When stale data is encountered, it triggers a background `Task` to refresh the data.

**Potential Issue: Concurrent Background Refreshes**

Phoenix handles requests using multiple concurrent processes. ETS provides shared memory on a single node, and operations like checking the cache or updating it are generally safe. However, there's a subtle **race condition** specifically related to triggering the **background refresh task**:

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
*   While ETS operations themselves are fast and reasonably atomic, there's no mechanism *inherent in this Plug's ETS-based approach* to guarantee that only *one* process "wins" the right to start the background task during that tiny window between deciding and acting.

**Why Locking is NOT Applied to Synchronous Fetches:**

The plug **intentionally does not** attempt to prevent concurrent *synchronous* fetches (when data is missing entirely or too stale). Applying a lock here would mean:

1.  Request A misses the cache and starts a synchronous fetch, acquiring a hypothetical lock.
2.  Request B also misses the cache but would be *blocked*, waiting for Request A to finish *and* release the lock, even though Request B also needs the data immediately.
3.  This would significantly slow down responses during cache misses, which is generally undesirable. Allowing concurrent synchronous fetches, while slightly redundant, ensures requests aren't blocked waiting for *other* requests to fetch the same missing data. The first one to finish populates the cache.

**Alternative (More Complex) Solution: GenServer Coordinator**

A more robust way to guarantee that only one background refresh task runs at a time (on a single node) involves using a central coordinating process, typically a `GenServer`:

1.  **Coordinator:** A single `GenServer` process manages the state of which cache keys are currently being refreshed.
2.  **Plug Interaction:** When the `ISRPlug` detects stale data, instead of starting a `Task` directly, it sends a non-blocking message (e.g., `GenServer.cast`) to the Coordinator, requesting a refresh for the specific `cache_key`.
3.  **Serialized Decision:** The Coordinator processes these requests one by one. It checks its internal state. If a refresh for that key isn't already marked "in progress," it marks it, starts the background `Task`, and configures the Task to notify the Coordinator upon completion (to clear the "in progress" state). If a refresh *is* already marked, the Coordinator simply ignores the duplicate request.

**Why We Didn't Implement the GenServer:**

*   **Increased Complexity:** Requires adding and managing a dedicated GenServer process within your application's supervision tree.
*   **Potential Bottleneck:** While likely negligible for many use cases, the single GenServer becomes a serialization point for *all* background refresh triggers managed by instances of this plug.
*   **Added Resource:** Introduces another persistent process to the system.

**Current Trade-off:**

The current `ISRPlug` implementation prioritizes simplicity and avoids the overhead of a dedicated GenServer coordinator. It accepts the possibility of occasional redundant *background* refresh tasks under high concurrent load on stale keys. This is often an acceptable trade-off, especially if the `:fetch_fun` is reasonably fast and idempotent, and downstream rate limits are not a major concern.

If absolute prevention of concurrent background refreshes is critical for your specific use case (e.g., very expensive fetches, strict rate limits), consider implementing a custom solution using the GenServer coordinator pattern described above.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request. (TODO: Add contribution guidelines).

## License

(TODO: Add License - e.g., MIT License).

