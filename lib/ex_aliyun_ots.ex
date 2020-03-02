defmodule ExAliyunOts do
  @moduledoc ~S"""
  The `ExAliyunOts` module provides a tablestore-based API as a client for working with Alibaba TableStore product servers.

  Here are links to official documents in [Chinese](https://help.aliyun.com/document_detail/27280.html) | [English](https://www.alibabacloud.com/help/product/27278.html)

  ## Configuration

      config :ex_aliyun_ots, :my_instance
        name: "MyInstanceName",
        endpoint: "MyInstanceEndpoint",
        access_key_id: "MyAliyunRAMKeyID",
        access_key_secret: "MyAliyunRAMKeySecret"

      config :ex_aliyun_ots,
        instances: [:my_instance],
        debug: false,
        enable_tunnel?: false

  * `debug`, optional, specifies whether to enable debug logger, by default it's false, and please DO NOT use debug mode in production.
  * `enable_tunnel?`, optional, specifies whether to enable tunnel functions, there will startup tunnel related `Supervisor` and `Registry` when enable it, by default it's false.

  ## Using ExAliyunOts

  To use `ExAliyunOts`, a module that calls `use ExAliyunOts` has to be defined:

      defmodule MyApp.TableStore do
        use ExAliyunOts, instance: :my_instance
      end

  This automatically defines some macros and functions in the `MyApp.TableStore` module, here are some examples:

      import MyApp.TableStore

      # Create table
      create_table "table",
        [{"pk1", :integer}, {"pk2", :string}]

      # Put row
      put_row "table",
        [{"pk1", "id1"}],
        [{"attr1", 10}, {"attr2", "attr2_value"}],
        condition: condition(:expect_not_exist),
        return_type: :pk

      # Search index
      search "table", "index_name",
        search_query: [
          query: match_query("age", 28),
          sort: [
            field_sort("age", order: :desc)
          ]
        ]

      # Local transaction
      start_local_transaction "table", {"partition_key", "partition_value"}

  ## ExAliyunOts API

  There are two ways to use ExAliyunOts:

    * using macros and functions from your own ExAliyunOts module, like `MyApp.TableStore`.
    * using macros and functions from the `ExAliyunOts` module.

  All defined functions and macros in `ExAliyunOts` are available and referrible for your own ExAliyunOts module as well, except that the given arity of functions may
  different, because the `instance` parameter is NOT needed in your own ExAliyunOts module although the `ExAliyunOts` module defines it.
  """

  alias ExAliyunOts.{Var, Client}

  alias ExAliyunOts.Const.{OperationType, ReturnType, RowExistence, FilterType, ComparatorType, LogicOperator, Direction}

  require OperationType
  require ReturnType
  require RowExistence
  require FilterType
  require ComparatorType
  require LogicOperator
  require Direction

  @regex_filter_options ~r/^(.+?)(\[.+?\])$/

  defmacro __using__(opts \\ []) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, __CALLER__))

    quote do

      @instance Keyword.get(unquote(opts), :instance)

      use ExAliyunOts.Constants

      import ExAliyunOts, only: [
        filter: 1,
        condition: 1,
        condition: 2,
        pagination: 1
      ]

      @before_compile ExAliyunOts.Compiler
    end
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/35193.html) | [English](https://www.alibabacloud.com/help/doc-detail/35193.html)

  ## Example

      import MyApp.TableStore

      get_row table_name1, [{"key", "key1"}],
        columns_to_get: ["name", "level"],
        filter: filter(("name[ignore_if_missing: true, latest_version_only: true]" == var_name and "age" > 1) or ("class" == "1"))

      batch_get [
        get(
          table_name2,
          [{"key", "key1"}],
          filter: filter "age" >= 10
        )
      ]

  ## Options

    * `ignore_if_missing`, used when attribute column not existed.
      * if a attribute column is not existed, when set `[ignore_if_missing: true]` in filter expression, there will ignore this row data in the returned result;
      * if a attribute column is existed, the returned result won't be affected no matter true or false was set.
    * `latest_version_only`, used when attribute column has multiple versions.
      * if set `[latest_version_only: true]`, there will only check the value of the latest version is matched or not, by default it's set as `[latest_version_only: true]`;
      * if set `[latest_version_only: false]`, there will check the value of all versions are matched or not.

  """
  defmacro filter(filter_expr) do
    quote do
      ast_expr = unquote(Macro.escape(filter_expr))
      context_binding = binding()
      ExAliyunOts.expressions_to_filter(ast_expr, context_binding)
    end
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/35194.html) | [English](https://www.alibabacloud.com/help/doc-detail/35194.html)

  ## Example

      import MyApp.TableStore

      update_row "table", [{"pk", "pk1"}],
        delete_all: ["attr1", "attr2"],
        return_type: :pk,
        condition: condition(:expect_exist)

  The available `existence` options: `:expect_exist` | `:expect_not_exist` | `:ignore`, here are some use cases for your reference:

  Use `condition(:expect_exist)`, expect the primary keys to row is existed.
    * for `put_row/5`, if the primary keys have auto increment column type, meanwhile the target primary keys row is existed,
    only use `condition(:expect_exist)` can successfully overwrite the row.
    * for `update_row/4`, if the primary keys have auto increment column type, meanwhile the target primary keys row is existed,
    only use `condition(:expect_exist)` can successfully update the row.
    * for `delete_row/4`, no matter what primary keys type are, use `condition(:expect_exist)` can successfully delete the row.

  Use `condition(:expect_not_exist)`, expect the primary_keys to row is not existed.
    * for `put_row/5`, if the primary keys have auto increment type,
      - while the target primary keys row is existed, only use `condition(:expect_exist)` can successfully put the row;
      - while the target primary keys row is not existed, only use `condition(:ignore)` can successfully put the row.

  Use `condition(:ignore)`, ignore the row existence check
    * for `put_row/5`, if the primary keys have auto increment column type, meanwhile the target primary keys row is not existed,
    only use `condition(:ignore)` can successfully put the row.
    * for `update_row/4`, if the primary keys have auto increment column type, meanwhile the target primary keys row is not existed,
    only use `condition(:ignore)` can successfully update the row.
    * for `delete_row/4`, no matter what primary keys type are, use `condition(:ignore)` can successfully delete the row if existed.

  The `batch_write/3` operation is a collection of put_row / update_row / delete_row operations.
  """
  @spec condition(existence :: :expect_exist | :expect_not_exist | :ignore) :: map()
  def condition(existence) do
    map_condition(existence)
  end


  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/44573.html) | [English](https://www.alibabacloud.com/help/doc-detail/44573.html)

  ## Example

      import MyApp.TableStore

      get_row table_name,
        [{"key", "1"}],
        start_column: "room",
        filter: pagination(offset: 0, limit: 3)

  Use `pagination/1` for `:filter` options when get row.
  """
  @spec pagination(options :: Keyword.t()) :: map()
  def pagination(options) do
    offset = Keyword.get(options, :offset)
    limit = Keyword.get(options, :limit)
    %Var.Filter{
      filter_type: FilterType.column_pagination,
      filter: %Var.ColumnPaginationFilter{offset: offset, limit: limit}
    }
  end

  @doc """
  Similar to `condition/1` and support use filter expression (please see `filter/1`) as well, please refer them for details.

  ## Example

      import MyApp.TableStore

      delete_row "table",
        [{"key", "key1"}, {"key2", "key2"}],
        condition: condition(:expect_exist, "attr_column" == "value2")

  """
  defmacro condition(existence, filter_expr) do
    quote do
      condition = ExAliyunOts.map_condition(unquote(existence))
      ast_expr = unquote(Macro.escape(filter_expr))
      context_binding = binding()
      column_condition = ExAliyunOts.expressions_to_filter(ast_expr, context_binding)
      %{condition | column_condition: column_condition}
    end
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27312.html) | [English](https://www.alibabacloud.com/help/doc-detail/27312.html)

  ## Example

      create_table "table_name2",
        [{"key1", :string}, {"key2", :auto_increment}]

      create_table "table_name3", 
        [{"key1", :string}],
        reserved_throughput_write: 1,
        reserved_throughput_read: 1,
        time_to_live: 100_000,
        max_versions: 3,
        deviation_cell_version_in_sec: 6_400,
        stream_spec: [is_enabled: true, expiration_time: 2]

  ## Options

    * `:reserved_throughput_write`, optional, the reserved throughput write of table, by default it is 0.
    * `:reserved_throughput_read`, optional, the reserved throughput read of table, by default it is 0.
    * `time_to_live`, optional, the data storage time to live in seconds, the minimux settable value is 864_000 seconds (one day), by default it is -1 (for permanent).
    * `:max_versions`, optional, the version of table, by default it is 1 that specifies there is only one version for columns.
    * `:deviation_cell_version_in_sec`, optional, maximum version deviation, by default it is 864_000 seconds (one day).
    * `:stream_spec`, specifies whether enable stream, by default it is not enable stream feature.
      - `:is_enabled`, enable or not enable stream, use `true` or `false`;
      - `:expiration_time`, the expiration time of stream.
  """
  @spec create_table(instance :: atom(), table :: String.t(), pk_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def create_table(instance, table, pk_keys, options \\ []) do
    var_create_table = %Var.CreateTable{
      table_name: table,
      primary_keys: pk_keys
    }
    prepared_var = map_options(var_create_table, options)
    Client.create_table(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27314.html) | [English](https://www.alibabacloud.com/help/doc-detail/27314.html)

  ## Example

      import MyApp.TableStore

      delete_table("table_name")
  """
  @spec delete_table(instance :: atom(), table :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def delete_table(instance, table) do
    Client.delete_table(instance, table)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27313.html) | [English](https://www.alibabacloud.com/help/doc-detail/27313.html)

  ## Example

      import MyApp.TableStore

      list_table()
  """
  @spec list_table(instance :: atom())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def list_table(instance) do
    Client.list_table(instance)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27315.html) | [English](https://www.alibabacloud.com/help/doc-detail/27315.html)

  ## Example

      import MyApp.TableStore

      update_table "table_name",
        reserved_throughput_write: 10,
        time_to_live: 200_000,
        stream_spec: [is_enabled: false]

  ## Options

    Please see options of `create_table/4`.
  """
  @spec update_table(instance :: atom(), table :: String.t(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def update_table(instance, table, options \\ []) do
    var_update_table = %Var.UpdateTable{
      table_name: table
    }
    prepared_var = map_options(var_update_table, options)
    Client.update_table(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27307.html) | [English](https://www.alibabacloud.com/help/doc-detail/27307.html)

  ## Example

      import MyApp.TableStore

      describe_table(table_name)
  """
  @spec describe_table(instance :: atom(), table :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def describe_table(instance, table) do
    Client.describe_table(instance, table)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27310.html) | [English](https://www.alibabacloud.com/help/doc-detail/27310.html)

  ## Example

      import MyApp.TableStore

      batch_get [
        get(table_name1, [[{"key1", 1}, {"key2", "1"}]]),
        get(
          table_name2,
          [{"key1", "key1"}],
          columns_to_get: ["name", "age"],
          filter: filter "age" >= 10
        )
      ]

  The batch get operation can be considered as a collection of mulitple `get/3` operations.
  """
  @spec batch_get(instance :: atom(), requests :: list())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def batch_get(instance, requests) do
    Client.batch_get_row(instance, requests)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27311.html) | [English](https://www.alibabacloud.com/help/doc-detail/27311.html)

  ## Example
  
      import MyApp.TableStore

      batch_write [
        {"table1", [
          write_delete([{"key1", 5}, {"key2", "5"}],
            return_type: :pk,
            condition: condition(:expect_exist, "attr1" == 5)),
          write_put([{"key1", 6}, {"key2", "6"}],
            [{"new_put_val1", "val1"}, {"new_put_val2", "val2"}],
            condition: condition(:expect_not_exist),
            return_type: :pk)
        ]},
        {"table2", [
          write_update([{"key1", "new_tab3_id2"}],
            put: [{"new_put1", "u1"}, {"new_put2", 2.5}],
            condition: condition(:expect_not_exist)),
          write_put([{"key1", "new_tab3_id3"}],
            [{"new_put1", "put1"}, {"new_put2", 10}],
            condition: condition(:expect_not_exist))
        ]}
      ]

  The batch write operation can be considered as a collection of mulitple `write_put/3`, `write_update/2` and `write_delete/2` operations.
  """
  @spec batch_write(instance :: atom(), requests :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def batch_write(instance, requests, options \\ [])
  def batch_write(instance, requests, options) when is_list(requests) do
    batch_write_requests =
      Enum.map(requests, fn({table, write_rows}) ->
        %Var.BatchWriteRequest{
          table_name: table,
          rows: write_rows
        }
      end)
    Client.batch_write_row(instance, batch_write_requests, options)
  end
  def batch_write(instance, {table, write_rows}, options) do
    batch_write_request = %Var.BatchWriteRequest{
      table_name: table,
      rows: write_rows
    }
    Client.batch_write_row(instance, batch_write_request, options)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27305.html) | [English](https://www.alibabacloud.com/help/doc-detail/27305.html)

  ## Example

      import MyApp.TableStore

      get_row "table1",
        [{"key1", "id1"}, {"key2", "id2"}],
        columns_to_get: ["name", "level"],
        filter: filter(("name[ignore_if_missing: true, latest_version_only: true]" == var_name and "age" > 1) or ("class" == "1"))

      get_row "table2",
        [{"key", "1"}],
        start_column: "room",
        filter: pagination(offset: 0, limit: 3)

      get_row "table3",
        [{"key", "1"}],
        transaction_id: "transaction_id"

  ## Options

    `:columns_to_get`, optional, fetch the special fields, by default it returns all fields.
    `:start_column`, optional, specifies the start column when using for wide-row-read, the returned result contains this `:start_column`.
    `:end_column`, optional, specifies the end column when using for wide-row-read, the returned result does not contain this `:end_column`.
    `:filter`, optional, filter the return results in the server side, please see `filter/1` for details.
    `:max_versions`, optional, how many versions need to return in results, by default it is 1.
    `:time_range`, optional, read data by timestamp range, support two ways to use it:
      - time_range: {start_timestamp, end_timestamp}, the timestamp in the range (include `start_timestamp` but exclude `end_timestamp`)
      and then will return in the results.
      - time_range: specail_timestamp, exactly match and then will return in the results.
      - `:time_range` and `:max_versions` are mutually exclusive, by default use `max_versions: 1` and `time_range: nil`.
    `:transaction_id`, optional, read operation within local transaction.
  """
  @spec get_row(instance :: atom(), table :: String.t(), pk_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def get_row(instance, table, pk_keys, options \\ []) do
    var_get_row = %Var.GetRow{
      table_name: table,
      primary_keys: pk_keys
    }
    prepared_var = map_options(var_get_row, options)
    Client.get_row(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27306.html) | [English](https://www.alibabacloud.com/help/doc-detail/27306.html)

  ## Example

      import MyApp.TableStore

      put_row "table1",
        [{"key1", "id1"}],
        [{"name", "name1"}, {"age", 20}],
        condition: condition(:expect_not_exist),
        return_type: :pk

      put_row "table2",
        [{"key1", "id1"}],
        [{"name", "name1"}, {"age", 20}],
        condition: condition(:expect_not_exist),
        transaction_id: "transaction_id"
        return_type: :pk

  ## Options

    `:condition`, required, please see `condition/1` or `condition/2` for details.
    `:return_type`, optional, whether return the primary keys after put row, available options are `:pk` | `:none`, by default it is `:none`.
    `:transaction_id`, optional, write operation within local transaction.

  """
  @spec put_row(instance :: atom(), table :: String.t(), pk_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def put_row(instance, table, pk_keys, attrs, options \\ []) do
    var_put_row = %Var.PutRow{
      table_name: table,
      primary_keys: pk_keys,
      attribute_columns: attrs,
    }
    prepared_var = map_options(var_put_row, options)
    Client.put_row(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27307.html) | [English](https://www.alibabacloud.com/help/doc-detail/27307.html)

  ## Example

      import MyApp.TableStore

      value = "1"
      update_row "table1",
        [{"key1", 2}, {"key2", "2"}],
        delete: [{"attr2", nil, 1524464460}],
        delete_all: ["attr1"],
        put: [{"attr3", "put_attr3"}],
        return_type: :pk,
        condition: condition(:expect_exist, "attr2" == value)

      update_row "table2",
        [{"key1", 1}],
        put: [{"attr1", "put_attr1"}],
        increment: [{"count", 1}],
        return_type: :after_modify,
        return_columns: ["count"],
        condition: condition(:ignore)

      update_row "table3",
        [partition_key],
        put: [{"new_attr1", "a1"}],
        delete_all: ["level", "size"],
        condition: condition(:ignore),
        transaction_id: "transaction_id"

  ## Options

    * `:put`, optional, require to be valid value, e.g. `[{"field1", "value"}, {...}]`, insert a new column if this field is not existed, or overwrite this field if existed.
    * `:delete`, optional, delete the special version of a column or columns, please pass the column's version (timestamp) in `:delete` option, e.g. [{"field1", nil, 1524464460}, ...].
    * `:delete_all`, optional, delete all versions of a column or columns, e.g. ["field1", "field2", ...].
    * `:increment`, optional, attribute column(s) base on atomic counters for increment or decreasement, require the value of column is integer.
      - for increment, `increment: [{"count", 1}]`;
      - for decreasement, `increment: [{"count", -1}]`.
    * `:return_type`, optional, whether return the primary keys after update row, available options are `:pk` | `:none` | `:after_modify`, by default it is `:none`.
      - if use atomic counters, must set `return_type: :after_modify`.
    * `:condition`, required, please see `condition/1` or `condition/2` for details.
    * `:transaction_id`, optional, write operation within local transaction.
  """
  @spec update_row(instance :: atom(), table :: String.t(), pk_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def update_row(instance, table, pk_keys, options \\ []) do
    prepared_var =
      %Var.UpdateRow{
        table_name: table,
        primary_keys: pk_keys,
      }
      |> map_options(options)
      |> Map.put(:updates, map_updates(options))

    Client.update_row(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27308.html) | [English](https://www.alibabacloud.com/help/doc-detail/27308.html)

  ## Example

      import MyApp.TableStore

      delete_row "table1",
        [{"key1", 3}, {"key2", "3"}],
        condition: condition(:expect_exist, "attr2" == "value2")

      delete_row "table1",
        [{"key1", 3}, {"key2", "3"}],
        condition: condition(:expect_exist, "attr2" == "value2"),
        transaction_id: "transaction_id"

  ## Options

    * `:condition`, required, please see `condition/1` or `condition/2` for details.
    * `:transaction_id`, optional, write operation within local transaction.
  """
  @spec delete_row(instance :: atom(), table :: String.t(), pk_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def delete_row(instance, table, pk_keys, options \\ []) do
    var_delete_row = %Var.DeleteRow{
      table_name: table,
      primary_keys: pk_keys
    }
    prepared_var = map_options(var_delete_row, options)
    Client.delete_row(instance, prepared_var)
  end

  @doc """
  Used in batch get operation, please see `batch_get/2` for details.

  ## Options

  The available options are same as `get_row/4`.
  """
  @spec get(table :: String.t(), pk_keys :: list(), options :: Keyword.t()) :: map()
  def get(table, pk_keys, options \\ []) do
    var_get_row = %Var.GetRow{
      table_name: table,
      primary_keys: pk_keys,
    }
    map_options(var_get_row, options)
  end

  @doc """
  Used in batch write operation, please see `batch_write/2` for details.

  ## Options

  The available options are same as `put_row/5`.
  """
  @spec write_put(pk_keys :: list(), attrs :: list(), options :: Keyword.t()) :: map()
  def write_put(pk_keys, attrs, options \\ []) do
    var_batch_put_row = %Var.RowInBatchWriteRequest{
      type: OperationType.put,
      primary_keys: pk_keys,
      updates: attrs,
    }
    map_options(var_batch_put_row, options)
  end

  @doc """
  Used in batch write operation, please see `batch_write/2` for details.

  ## Options

  The available options are same as `update_row/4`.
  """
  @spec write_update(pk_keys :: list(), options :: Keyword.t()) :: map()
  def write_update(pk_keys, options \\ []) do
    var_batch_update_row = %Var.RowInBatchWriteRequest{
      type: OperationType.update,
      primary_keys: pk_keys,
      updates: map_updates(options)
    }
    map_options(var_batch_update_row, options)
  end

  @doc """
  Used in batch write operation, please see `batch_write/2` for details.

  ## Options

  The available operation same as `delete_row/4`.
  """
  @spec write_delete(pk_keys :: list(), options :: Keyword.t()) :: map()
  def write_delete(pk_keys, options \\ []) do
    var_batch_delete_row = %Var.RowInBatchWriteRequest{
      type: OperationType.delete,
      primary_keys: pk_keys,
    }
    map_options(var_batch_delete_row, options)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/27309.html) | [English](https://www.alibabacloud.com/help/doc-detail/27309.html)

  ## Example

      import MyApp.TableStore

      get_range "table_name",
        [{"key1", 1}, {"key2", :inf_min}],
        [{"key1", 4}, {"key2", :inf_max}],
        direction: :forward

      get_range "table_name",
        [{"key1", 1}, {"key2", :inf_min}],
        [{"key1", 4}, {"key2", :inf_max}],
        time_range: {1525922253224, 1525923253224},
        direction: :forward

      get_range "table_name",
        [{"key1", 1}, {"key2", :inf_min}],
        [{"key1", 4}, {"key2", :inf_max}],
        time_range: 1525942123224,
        direction: :forward

  ## Options

    `:direction`, required, the order of fetch data, available options are `:forward` | `:backward`, by it is `:forward`.
      - `:forward`, this query is performed in the order of primary key in ascending, in this case, input `inclusive_start_primary_keys` should less
      than `exclusive_end_primary_keys`;
      - `:backward`, this query is performed in the order of primary key in descending, in this case, input `inclusive_start_primary_keys` should greater
      than `exclusive_end_primary_keys`.
    `:columns_to_get`, optional, fetch the special fields, by default it returns all fields.
    `:start_column`, optional, specifies the start column when using for wide-row-read, the returned result contains this `:start_column`.
    `:end_column`, optional, specifies the end column when using for wide-row-read, the returned result does not contain this `:end_column`.
    `:filter`, optional, filter the return results in the server side, please see `filter/1` for details.
    `:max_versions`, optional, how many versions need to return in results, by default it is 1.
    `:time_range`, optional, read data by timestamp range, support two ways to use it:
      - time_range: {start_timestamp, end_timestamp}, the timestamp in the range (include `start_timestamp` but exclude `end_timestamp`)
      and then will return in the results.
      - time_range: specail_timestamp, exactly match and then will return in the results.
      - `:time_range` and `:max_versions` are mutually exclusive, by default use `max_versions: 1` and `time_range: nil`.
    `:transaction_id`, optional, read operation within local transaction.

  """
  @spec get_range(instance :: atom(), inclusive_start_primary_keys :: list(), exclusive_end_primary_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def get_range(instance, table, inclusive_start_primary_keys, exclusive_end_primary_keys, options \\ [])
  def get_range(instance, table, inclusive_start_primary_keys, exclusive_end_primary_keys, options) when is_list(inclusive_start_primary_keys) do
    var_get_range = %Var.GetRange{
      table_name: table,
      inclusive_start_primary_keys: inclusive_start_primary_keys,
      exclusive_end_primary_keys: exclusive_end_primary_keys
    }
    prepared_var = map_options(var_get_range, options)
    Client.get_range(instance, prepared_var, nil)
  end
  def get_range(instance, table, inclusive_start_primary_keys, exclusive_end_primary_keys, options) when is_binary(inclusive_start_primary_keys) do
    var_get_range = %Var.GetRange{
      table_name: table,
      exclusive_end_primary_keys: exclusive_end_primary_keys
    }
    prepared_var = map_options(var_get_range, options)
    Client.get_range(instance, prepared_var, inclusive_start_primary_keys)
  end

  @doc """
  As a client SDK wrapper built on `get_range/5` to fetch a large data set by iterate.

  ## Example

      import MyApp.TableStore

      iterate_all_range table_name1,
        [{"key1", 1}, {"key2", :inf_min}],
        [{"key1", 4}, {"key2", :inf_max}],
        direction: :forward

  ## Options

  Please see options of `get_range/5` for details.
  """
  @spec iterate_all_range(instance :: atom(), table :: String.t(), inclusive_start_primary_keys :: list(), exclusive_end_primary_keys :: list(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def iterate_all_range(instance, table, inclusive_start_primary_keys, exclusive_end_primary_keys, options \\ []) do
    var_iterate_all_range = %Var.GetRange{
      table_name: table,
      inclusive_start_primary_keys: inclusive_start_primary_keys,
      exclusive_end_primary_keys: exclusive_end_primary_keys
    }
    prepared_var = map_options(var_iterate_all_range, options)
    Client.iterate_get_all_range(instance, prepared_var)
  end

  @doc """
  The one entrance to use search index functions, please see `ExAliyunOts.Search` module for details.

  Official document in [Chinese](https://help.aliyun.com/document_detail/91974.html) | [English](https://www.alibabacloud.com/help/doc-detail/91974.html)
  """
  @spec search(instance :: atom(), table :: String.t(), index_name :: String.t(), options :: Keyword.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def search(instance, table, index_name, options) do
    var_search_request = %Var.Search.SearchRequest{
      table_name: table,
      index_name: index_name
    }
    prepared_var = ExAliyunOts.Search.map_search_options(var_search_request, options)
    Client.search(instance, prepared_var)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/117477.html) | [English](https://www.alibabacloud.com/help/doc-detail/117477.html)

  ## Example

      import MyApp.TableStore

      list_search_index("table")
  """
  @spec list_search_index(instance :: atom(), table :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def list_search_index(instance, table) do
    Client.list_search_index(instance, table)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/117478.html) | [English](https://www.alibabacloud.com/help/doc-detail/117478.html)

  ## Example

      import MyApp.TableStore

      delete_search_index("table", "index_name")
  """
  @spec delete_search_index(instance :: atom(), table :: String.t(), index_name :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def delete_search_index(instance, table, index_name) do
    var_delete_request = %Var.Search.DeleteSearchIndexRequest{
      table_name: table,
      index_name: index_name
    }
    Client.delete_search_index(instance, var_delete_request)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/117475.html) | [English](https://www.alibabacloud.com/help/doc-detail/117475.html)

  ## Example

      import MyApp.TableStore

      describe_search_index("table", "index_name")
  """
  @spec describe_search_index(instance :: atom(), table :: String.t(), index_name :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def describe_search_index(instance, table, index_name) do
    var_describe_request = %Var.Search.DescribeSearchIndexRequest{
      table_name: table,
      index_name: index_name
    }
    Client.describe_search_index(instance, var_describe_request)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/93819.html) | [English](https://www.alibabacloud.com/help/doc-detail/93819.html)

  ## Example

      import MyApp.TableStore

      partition_key = {"key", "key1"}
      start_local_transaction("table", partition_key)
  """
  @spec start_local_transaction(instance :: atom(), table :: String.t(), partition_key :: tuple())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def start_local_transaction(instance, table, partition_key) do
    var_start_local_transaction = %Var.Transaction.StartLocalTransactionRequest{
      table_name: table,
      partition_key: partition_key
    }
    Client.start_local_transaction(instance, var_start_local_transaction)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/93819.html) | [English](https://www.alibabacloud.com/help/doc-detail/93819.html)

  ## Example

      import MyApp.TableStore

      commit_transaction("transaction_id")
  """
  @spec commit_transaction(instance :: atom(), transaction_id :: String.t())
    :: {:ok, map()} | {:error, ExAliyunOts.Error.t()}
  def commit_transaction(instance, transaction_id) do
    Client.commit_transaction(instance, transaction_id)
  end

  @doc """
  Official document in [Chinese](https://help.aliyun.com/document_detail/93819.html) | [English](https://www.alibabacloud.com/help/doc-detail/93819.html)

  ## Example

      import MyApp.TableStore

      abort_transaction("transaction_id")
  """
  def abort_transaction(instance, transaction_id) do
    Client.abort_transaction(instance, transaction_id)
  end

  @doc false
  def map_condition(:ignore) do
    %Var.Condition{
      row_existence: RowExistence.ignore
    }
  end
  def map_condition(:expect_exist) do
    %Var.Condition{
      row_existence: RowExistence.expect_exist
    }
  end
  def map_condition(:expect_not_exist) do
    %Var.Condition{
      row_existence: RowExistence.expect_not_exist
    }
  end
  def map_condition(existence) do
    raise ExAliyunOts.RuntimeError, "Invalid existence: #{inspect existence} in condition, please use one of :ignore | :expect_exist | :expect_not_exist option."
  end

  @doc false
  def expressions_to_filter({:and, _, expressions}, binding) do
    %Var.Filter{
      filter_type: FilterType.composite_column,
      filter: %Var.CompositeColumnValueFilter{
        combinator: LogicOperator.and,
        sub_filters: Enum.map(expressions, fn(expr) -> 
          expressions_to_filter(expr, binding)
        end)
      }
    }
  end
  def expressions_to_filter({:not, _, expressions}, binding) do
    %Var.Filter{
      filter_type: FilterType.composite_column,
      filter: %Var.CompositeColumnValueFilter{
        combinator: LogicOperator.not,
        sub_filters: Enum.map(expressions, fn(expr) -> 
          expressions_to_filter(expr, binding)
        end)
      }
    }
  end
  def expressions_to_filter({:or, _, expressions}, binding) do
    %Var.Filter{
      filter_type: FilterType.composite_column,
      filter: %Var.CompositeColumnValueFilter{
        combinator: LogicOperator.or,
        sub_filters: Enum.map(expressions, fn(expr) ->
          expressions_to_filter(expr, binding)
        end)
      }
    }
  end
  def expressions_to_filter({:==, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.eq, column_name, column_value, binding)
  end
  def expressions_to_filter({:>, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.gt, column_name, column_value, binding)
  end
  def expressions_to_filter({:>=, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.ge, column_name, column_value, binding)
  end
  def expressions_to_filter({:!=, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.not_eq, column_name, column_value, binding)
  end
  def expressions_to_filter({:<, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.lt, column_name, column_value, binding)
  end
  def expressions_to_filter({:<=, _, [column_name, column_value]}, binding) do
    prepare_single_column_value_filter(ComparatorType.le, column_name, column_value, binding)
  end

  defp prepare_single_column_value_filter(comparator, column_name, column_value, binding) do
    {column_name, options} = check_signal_col_val_filter_options(column_name)
    filter = %Var.SingleColumnValueFilter{
      comparator: comparator,
      column_name: column_name,
      column_value: map_filter_column_value(column_value, binding),
    }
    filter_with_options = map_options(filter, options)
    %Var.Filter{
      filter_type: FilterType.single_column,
      filter: filter_with_options
    }
  end

  defp check_signal_col_val_filter_options(column_content) do
    case Regex.run(@regex_filter_options, column_content) do
      nil ->
        {column_content, nil}
      [_, column_name, options_str] ->
        {options, _} = Code.eval_string(options_str)
        {column_name, options}
      _ ->
        raise ExAliyunOts.RuntimeError, "filter expression: #{inspect column_content}"
    end
  end

  defp map_filter_column_value({column_value_bound_var, _, _} = ast, binding) do
    prepared = Keyword.get(binding, column_value_bound_var)
    if prepared == nil do
      raise ExAliyunOts.RuntimeError, "Invalid expression `#{Macro.to_string(ast)}` in context, please use a variable refer the value in filter expression."
    else
      prepared
    end
  end
  defp map_filter_column_value(column_value, _binding) do
    column_value
  end

  defp map_options(var, nil), do: var
  defp map_options(var, options) do
    options
    |> Keyword.keys()
    |> Enum.reduce(var, fn(key, acc) ->
      value = Keyword.get(options, key)
      if value != nil and Map.has_key?(var, key) do
        case key do
          :return_type ->
            Map.put(acc, key, map_return_type(value))
          :direction ->
            Map.put(acc, key, map_direction(value))
          :stream_spec ->
            Map.put(acc, key, map_stream_spec(value))
          :time_range ->
            Map.put(acc, key, map_time_range(value))
          _ ->
            Map.put(acc, key, value)
        end
      else
        acc
      end
    end)
  end

  defp map_return_type(nil), do: ReturnType.none
  defp map_return_type(:none), do: ReturnType.none
  defp map_return_type(:pk), do: ReturnType.pk
  defp map_return_type(:after_modify), do: ReturnType.after_modify
  defp map_return_type(ReturnType.none), do: ReturnType.none
  defp map_return_type(ReturnType.pk), do: ReturnType.pk
  defp map_return_type(ReturnType.after_modify), do: ReturnType.after_modify
  defp map_return_type(invalid_return_type) do
    raise ExAliyunOts.RuntimeError, "invalid return_type: #{inspect invalid_return_type}"
  end

  defp map_direction(:backward), do: Direction.backward
  defp map_direction(:forward), do: Direction.forward
  defp map_direction(Direction.backward), do: Direction.backward
  defp map_direction(Direction.forward), do: Direction.forward
  defp map_direction(invalid_direction) do
    raise ExAliyunOts.RuntimeError, "invalid direction: #{inspect invalid_direction}"
  end

  defp map_stream_spec(values) do
    is_enabled = Keyword.get(values, :is_enabled)
    expiration_time = Keyword.get(values, :expiration_time)
    %Var.StreamSpec{is_enabled: is_enabled, expiration_time: expiration_time}
  end

  defp map_time_range(specific_time) when is_integer(specific_time) do
    %Var.TimeRange{specific_time: specific_time}
  end
  defp map_time_range({start_time, end_time}) when is_integer(start_time) and is_integer(end_time) do
    %Var.TimeRange{start_time: start_time, end_time: end_time}
  end

  defp map_updates(options) do
    Enum.reduce([:delete, :delete_all, :put, :increment], %{}, fn(update_operation, acc) ->
      {matched_update, _rest_opts} = Keyword.pop(options, update_operation)
      if matched_update != nil do
        Map.put(acc, map_operation_type(update_operation), matched_update)
      else
        acc
      end
    end)
  end

  defp map_operation_type(:put), do: OperationType.put
  defp map_operation_type(:delete), do: OperationType.delete
  defp map_operation_type(:delete_all), do: OperationType.delete_all
  defp map_operation_type(:increment), do: OperationType.increment
  defp map_operation_type(OperationType.put), do: OperationType.put
  defp map_operation_type(OperationType.delete), do: OperationType.delete
  defp map_operation_type(OperationType.delete_all), do: OperationType.delete_all
  defp map_operation_type(OperationType.increment), do: OperationType.increment
  defp map_operation_type(invalid_operation_type) do
    raise ExAliyunOts.RuntimeError, "invalid operation_type: #{inspect invalid_operation_type}"
  end

end
