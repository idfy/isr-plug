ExUnit.start()

# Ensure the ETS table used in tests is cleaned up
# Use a specific table name for tests to avoid conflicts
Application.put_env(:isr_plug, :test_ets_table, :isr_plug_test_cache)

# Clean up ETS table before tests run
table = Application.get_env(:isr_plug, :test_ets_table)
# Delete if exists, ignore error if not
try do
  :ets.delete(table)
rescue
  # Table doesn't exist
  ArgumentError -> :ok
end
