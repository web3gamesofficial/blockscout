defmodule BlockScoutWeb.API.V2.AddressController do
  use BlockScoutWeb, :controller

  import BlockScoutWeb.Chain,
    only: [
      next_page_params: 3,
      next_page_params: 4,
      token_transfers_next_page_params: 3,
      paging_options: 1,
      split_list_by_page: 1,
      current_filter: 1,
      paging_params_with_fiat_value: 1
    ]

  import BlockScoutWeb.PagingHelper,
    only: [
      delete_parameters_from_next_page_params: 1,
      token_transfers_types_options: 1,
      address_transactions_sorting: 1,
      nft_token_types_options: 1
    ]

  import Explorer.MicroserviceInterfaces.BENS, only: [maybe_preload_ens: 1, maybe_preload_ens_to_address: 1]

  alias BlockScoutWeb.AccessHelper
  alias BlockScoutWeb.API.V2.{BlockView, TransactionView, WithdrawalView}
  alias Explorer.{Chain, Market}
  alias Explorer.Chain.{Address, Hash, Transaction}
  alias Explorer.Chain.Address.Counters
  alias Explorer.Chain.Token.Instance
  alias Indexer.Fetcher.{CoinBalanceOnDemand, TokenBalanceOnDemand}

  @transaction_necessity_by_association [
    necessity_by_association: %{
      [created_contract_address: :names] => :optional,
      [from_address: :names] => :optional,
      [to_address: :names] => :optional,
      :block => :optional,
      [created_contract_address: :smart_contract] => :optional,
      [from_address: :smart_contract] => :optional,
      [to_address: :smart_contract] => :optional
    },
    api?: true
  ]

  @token_transfer_necessity_by_association [
    necessity_by_association: %{
      :to_address => :optional,
      :from_address => :optional,
      :block => :optional,
      :transaction => :optional
    },
    api?: true
  ]

  @address_options [
    necessity_by_association: %{
      :names => :optional,
      :token => :optional
    },
    api?: true
  ]

  @contract_address_preloads [
    :smart_contract,
    :contracts_creation_internal_transaction,
    :contracts_creation_transaction
  ]

  @nft_necessity_by_association [
    necessity_by_association: %{
      :token => :optional
    }
  ]

  @api_true [api?: true]

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  def address(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, _address_hash, address} <- validate_address(address_hash_string, params, @address_options),
         fully_preloaded_address <-
           Address.maybe_preload_smart_contract_associations(address, @contract_address_preloads, @api_true) do
      CoinBalanceOnDemand.trigger_fetch(fully_preloaded_address)

      conn
      |> put_status(200)
      |> render(:address, %{address: fully_preloaded_address |> maybe_preload_ens_to_address()})
    end
  end

  def counters(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, _address_hash, address} <- validate_address(address_hash_string, params) do
      {validation_count} = Counters.address_counters(address, @api_true)

      transactions_from_db = address.transactions_count || 0
      token_transfers_from_db = address.token_transfers_count || 0
      address_gas_usage_from_db = address.gas_used || 0

      json(conn, %{
        transactions_count: to_string(transactions_from_db),
        token_transfers_count: to_string(token_transfers_from_db),
        gas_usage_count: to_string(address_gas_usage_from_db),
        validations_count: to_string(validation_count)
      })
    end
  end

  def token_balances(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      token_balances =
        address_hash
        |> Chain.fetch_last_token_balances(@api_true)

      Task.start_link(fn ->
        TokenBalanceOnDemand.trigger_fetch(address_hash)
      end)

      conn
      |> put_status(200)
      |> render(:token_balances, %{token_balances: token_balances})
    end
  end

  def transactions(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      options =
        @transaction_necessity_by_association
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(current_filter(params))
        |> Keyword.merge(address_transactions_sorting(params))

      results_plus_one = Transaction.address_to_transactions_without_rewards(address_hash, options, false)
      {transactions, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page
        |> next_page_params(
          transactions,
          delete_parameters_from_next_page_params(params),
          &Transaction.address_transactions_next_page_params/1
        )

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:transactions, %{transactions: transactions |> maybe_preload_ens(), next_page_params: next_page_params})
    end
  end

  def token_transfers(
        conn,
        %{"address_hash_param" => address_hash_string, "token" => token_address_hash_string} = params
      ) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params),
         {:ok, token_address_hash, _token_address} <- validate_address(token_address_hash_string, params) do
      paging_options = paging_options(params)

      options =
        [
          necessity_by_association: %{
            :to_address => :optional,
            :from_address => :optional,
            :block => :optional,
            :token => :optional,
            :transaction => :optional
          }
        ]
        |> Keyword.merge(paging_options)
        |> Keyword.merge(@api_true)

      results =
        address_hash
        |> Chain.address_hash_to_token_transfers_by_token_address_hash(
          token_address_hash,
          options
        )
        |> Chain.flat_1155_batch_token_transfers()
        |> Chain.paginate_1155_batch_token_transfers(paging_options)

      {token_transfers, next_page} = split_list_by_page(results)

      next_page_params =
        next_page
        |> token_transfers_next_page_params(token_transfers, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:token_transfers, %{
        token_transfers: token_transfers |> maybe_preload_ens(),
        next_page_params: next_page_params
      })
    end
  end

  def token_transfers(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      paging_options = paging_options(params)

      options =
        @token_transfer_necessity_by_association
        |> Keyword.merge(paging_options)
        |> Keyword.merge(current_filter(params))
        |> Keyword.merge(token_transfers_types_options(params))

      results =
        address_hash
        |> Chain.address_hash_to_token_transfers_new(options)
        |> Chain.flat_1155_batch_token_transfers()
        |> Chain.paginate_1155_batch_token_transfers(paging_options)

      {token_transfers, next_page} = split_list_by_page(results)

      next_page_params =
        next_page
        |> token_transfers_next_page_params(token_transfers, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:token_transfers, %{
        token_transfers: token_transfers |> maybe_preload_ens(),
        next_page_params: next_page_params
      })
    end
  end

  def internal_transactions(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      full_options =
        [
          necessity_by_association: %{
            [created_contract_address: :names] => :optional,
            [from_address: :names] => :optional,
            [to_address: :names] => :optional,
            [created_contract_address: :smart_contract] => :optional,
            [from_address: :smart_contract] => :optional,
            [to_address: :smart_contract] => :optional
          }
        ]
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(current_filter(params))
        |> Keyword.merge(@api_true)

      results_plus_one = Chain.address_to_internal_transactions(address_hash, full_options)
      {internal_transactions, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page |> next_page_params(internal_transactions, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:internal_transactions, %{
        internal_transactions: internal_transactions |> maybe_preload_ens(),
        next_page_params: next_page_params
      })
    end
  end

  def logs(conn, %{"address_hash_param" => address_hash_string, "topic" => topic} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      prepared_topic = String.trim(topic)

      formatted_topic = if String.starts_with?(prepared_topic, "0x"), do: prepared_topic, else: "0x" <> prepared_topic

      options = params |> paging_options() |> Keyword.merge(topic: formatted_topic) |> Keyword.merge(@api_true)

      results_plus_one = Chain.address_to_logs(address_hash, false, options)

      {logs, next_page} = split_list_by_page(results_plus_one)

      next_page_params = next_page |> next_page_params(logs, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:logs, %{logs: logs |> maybe_preload_ens(), next_page_params: next_page_params})
    end
  end

  def logs(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      options = params |> paging_options() |> Keyword.merge(@api_true)

      results_plus_one = Chain.address_to_logs(address_hash, false, options)

      {logs, next_page} = split_list_by_page(results_plus_one)

      next_page_params = next_page |> next_page_params(logs, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:logs, %{logs: logs |> maybe_preload_ens(), next_page_params: next_page_params})
    end
  end

  def blocks_validated(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      full_options =
        [
          necessity_by_association: %{
            miner: :required,
            nephews: :optional,
            transactions: :optional,
            rewards: :optional
          }
        ]
        |> Keyword.merge(paging_options(params))
        |> Keyword.merge(@api_true)

      results_plus_one = Chain.get_blocks_validated_by_address(full_options, address_hash)
      {blocks, next_page} = split_list_by_page(results_plus_one)

      next_page_params = next_page |> next_page_params(blocks, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(BlockView)
      |> render(:blocks, %{blocks: blocks, next_page_params: next_page_params})
    end
  end

  def coin_balance_history(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, address}} <- {:not_found, Chain.hash_to_address(address_hash, @api_true, false)} do
      full_options = params |> paging_options() |> Keyword.merge(@api_true)

      results_plus_one = Chain.address_to_coin_balances(address, full_options)

      {coin_balances, next_page} = split_list_by_page(results_plus_one)

      next_page_params = next_page |> next_page_params(coin_balances, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> render(:coin_balances, %{coin_balances: coin_balances, next_page_params: next_page_params})
    end
  end

  def coin_balance_history_by_day(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      balances_by_day =
        address_hash
        |> Chain.address_to_balances_by_day(@api_true)

      conn
      |> put_status(200)
      |> render(:coin_balances_by_day, %{coin_balances_by_day: balances_by_day})
    end
  end

  def tokens(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      results_plus_one =
        address_hash
        |> Chain.fetch_paginated_last_token_balances(
          params
          |> paging_options()
          |> Keyword.merge(token_transfers_types_options(params))
          |> Keyword.merge(@api_true)
        )

      Task.start_link(fn ->
        TokenBalanceOnDemand.trigger_fetch(address_hash)
      end)

      {tokens, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page
        |> next_page_params(
          tokens,
          delete_parameters_from_next_page_params(params),
          &paging_params_with_fiat_value/1
        )

      conn
      |> put_status(200)
      |> render(:tokens, %{tokens: tokens, next_page_params: next_page_params})
    end
  end

  def withdrawals(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      options = @api_true |> Keyword.merge(paging_options(params))
      withdrawals_plus_one = address_hash |> Chain.address_hash_to_withdrawals(options)
      {withdrawals, next_page} = split_list_by_page(withdrawals_plus_one)

      next_page_params = next_page |> next_page_params(withdrawals, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(WithdrawalView)
      |> render(:withdrawals, %{withdrawals: withdrawals |> maybe_preload_ens(), next_page_params: next_page_params})
    end
  end

  def addresses_list(conn, params) do
    {addresses, next_page} =
      params
      |> paging_options()
      |> Keyword.merge(@api_true)
      |> Address.list_top_addresses()
      |> split_list_by_page()

    next_page_params = next_page_params(next_page, addresses, params)

    exchange_rate = Market.get_coin_exchange_rate()
    total_supply = Chain.total_supply()

    conn
    |> put_status(200)
    |> render(:addresses, %{
      addresses: addresses |> maybe_preload_ens(),
      next_page_params: next_page_params,
      exchange_rate: exchange_rate,
      total_supply: total_supply
    })
  end

  def tabs_counters(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      {validations, transactions, token_transfers, token_balances, logs, withdrawals, internal_txs} =
        Counters.address_limited_counters(address_hash, @api_true)

      conn
      |> put_status(200)
      |> json(%{
        validations_count: validations,
        transactions_count: transactions,
        token_transfers_count: token_transfers,
        token_balances_count: token_balances,
        logs_count: logs,
        withdrawals_count: withdrawals,
        internal_txs_count: internal_txs
      })
    end
  end

  def nft_list(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      results_plus_one =
        Instance.nft_list(
          address_hash,
          params
          |> paging_options()
          |> Keyword.merge(nft_token_types_options(params))
          |> Keyword.merge(@api_true)
          |> Keyword.merge(@nft_necessity_by_association)
        )

      {nfts, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page
        |> next_page_params(
          nfts,
          delete_parameters_from_next_page_params(params),
          &Instance.nft_list_next_page_params/1
        )

      conn
      |> put_status(200)
      |> render(:nft_list, %{token_instances: nfts, next_page_params: next_page_params})
    end
  end

  def nft_collections(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:ok, address_hash, _address} <- validate_address(address_hash_string, params) do
      results_plus_one =
        Instance.nft_collections(
          address_hash,
          params
          |> paging_options()
          |> Keyword.merge(nft_token_types_options(params))
          |> Keyword.merge(@api_true)
          |> Keyword.merge(@nft_necessity_by_association)
        )

      {collections, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page
        |> next_page_params(
          collections,
          delete_parameters_from_next_page_params(params),
          &Instance.nft_collections_next_page_params/1
        )

      conn
      |> put_status(200)
      |> render(:nft_collections, %{collections: collections, next_page_params: next_page_params})
    end
  end

  @doc """
  Checks if this valid address hash string, and this address is not prohibited address
  """
  @spec validate_address(String.t(), any(), Keyword.t()) ::
          {:format, :error}
          | {:not_found, {:error, :not_found}}
          | {:restricted_access, true}
          | {:ok, Hash.t(), Address.t()}
  def validate_address(address_hash_string, params, options \\ @api_true) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, address}} <- {:not_found, Chain.hash_to_address(address_hash, options, false)} do
      {:ok, address_hash, address}
    end
  end
end
