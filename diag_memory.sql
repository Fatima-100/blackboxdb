/* diag_memory.sql - why queries wait for a memory grant (RESOURCE_SEMAPHORE).
   Run in SSMS (any database). Read-only: it changes nothing.
   Run it once now, then paste ALL result grids in the chat. */

-- 1. Memory settings of the server
SELECT name, value_in_use FROM sys.configurations
 WHERE name IN ('max server memory (MB)', 'min server memory (MB)', 'min memory per query (KB)',
                'query wait (s)');

-- 2. Memory of the computer and of SQL Server
SELECT total_physical_memory_kb / 1024 AS computer_total_mb,
       available_physical_memory_kb / 1024 AS computer_free_mb,
       system_memory_state_desc
  FROM sys.dm_os_sys_memory;
SELECT physical_memory_in_use_kb / 1024 AS sql_in_use_mb,
       memory_utilization_percentage, process_physical_memory_low, process_virtual_memory_low
  FROM sys.dm_os_process_memory;

-- 3. The pool queries get their sort/hash memory from (waiter_count > 0 means queries are queued)
SELECT resource_semaphore_id, target_memory_kb / 1024 AS target_mb, available_memory_kb / 1024 AS available_mb,
       granted_memory_kb / 1024 AS granted_mb, grantee_count, waiter_count, timeout_error_count, forced_grant_count
  FROM sys.dm_exec_query_resource_semaphores;

-- 4. Who holds or waits for memory right now
SELECT session_id, requested_memory_kb / 1024 AS requested_mb, granted_memory_kb / 1024 AS granted_mb,
       wait_time_ms, query_cost
  FROM sys.dm_exec_query_memory_grants;

-- 5. Sessions on this server (look for old windows or programs still connected)
SELECT s.session_id, s.login_name, s.program_name, s.host_name, s.status, s.open_transaction_count
  FROM sys.dm_exec_sessions s WHERE s.is_user_process = 1;
