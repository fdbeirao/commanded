defmodule Commanded.Commands.CorrelationCasuationTest do
  use Commanded.StorageCase

  import Commanded.Assertions.EventAssertions

  alias Commanded.EventStore
  alias Commanded.ExampleDomain.{
    BankRouter,
    TransferMoneyProcessManager,
  }
  alias Commanded.ExampleDomain.BankAccount.Commands.{
    DepositMoney,
    OpenAccount,
    WithdrawMoney,
  }
  alias Commanded.ExampleDomain.BankAccount.Events.{
    BankAccountOpened,
    MoneyDeposited,
  }
  alias Commanded.ExampleDomain.MoneyTransfer.Commands.TransferMoney
  alias Commanded.Helpers.CommandAuditMiddleware

  setup do
    CommandAuditMiddleware.reset()
    {:ok, process_manager} = TransferMoneyProcessManager.start_link()

    on_exit fn ->
      Commanded.Helpers.Process.shutdown(process_manager)
    end
  end

  describe "`causation_id`" do
    test "should be `nil` when not provided" do
      open_account = %OpenAccount{account_number: "ACC123", initial_balance: 500}

      :ok = BankRouter.dispatch(open_account, causation_id: nil)

      assert [nil] = CommandAuditMiddleware.dispatched_commands(&(&1.causation_id))
    end

    test "should be copied to dispatched command" do
      causation_id = UUID.uuid4()
      open_account = %OpenAccount{account_number: "ACC123", initial_balance: 500}

      :ok = BankRouter.dispatch(open_account, causation_id: causation_id)

      # a command's `causation_id` is set by the value passed to command dispatch
      assert [^causation_id] = CommandAuditMiddleware.dispatched_commands(&(&1.causation_id))
    end

    test "should be set from `command_uuid` on created event" do
      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500})

      [command_uuid] = CommandAuditMiddleware.dispatched_commands(&(&1.command_uuid))
      [event] = EventStore.stream_forward("ACC123") |> Enum.to_list()

      # an event's `causation_id` is the dispatched command's `command_uuid`
      assert event.causation_id == command_uuid
    end

    test "should be copied onto commands/events by process manager" do
      transfer_uuid = UUID.uuid4()

      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500})
      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC456", initial_balance: 100})

      CommandAuditMiddleware.reset()

      :ok = BankRouter.dispatch(%TransferMoney{transfer_uuid: transfer_uuid, debit_account: "ACC123", credit_account: "ACC456", amount: 100})

      assert_receive_event MoneyDeposited, fn event -> assert event.transfer_uuid == transfer_uuid end

      # withdraw money command's `causation_id` should be money transfer requested event's id
      transfer_requested = EventStore.stream_forward(transfer_uuid) |> Enum.at(0)
      [_, causation_id, _] = CommandAuditMiddleware.dispatched_commands(&(&1.causation_id))
      assert causation_id == transfer_requested.event_id
    end
  end

  describe "`correlation_id`" do
    test "should default to a generated UUID when not provided" do
      open_account = %OpenAccount{account_number: "ACC123", initial_balance: 500}

      :ok = BankRouter.dispatch(open_account, correlation_id: nil)

      assert [correlation_id] = CommandAuditMiddleware.dispatched_commands(&(&1.correlation_id))
      refute is_nil(correlation_id)
      assert correlation_id |> UUID.string_to_binary!() |> is_binary()
    end

    test "should be copied to dispatched command" do
      correlation_id = UUID.uuid4()

      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500}, correlation_id: correlation_id)

      assert [^correlation_id] = CommandAuditMiddleware.dispatched_commands(&(&1.correlation_id))
    end

    test "should be set on all created events" do
      correlation_id = UUID.uuid4()

      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500}, correlation_id: correlation_id)
      :ok = BankRouter.dispatch(%WithdrawMoney{account_number: "ACC123", amount: 1_000}, correlation_id: correlation_id)

      events = EventStore.stream_forward("ACC123") |> Enum.to_list()
      assert length(events) == 3

      for event <- events do
        assert event.correlation_id == correlation_id
      end
    end

    test "should be copied onto commands/events by process manager" do
      correlation_id = UUID.uuid4()
      transfer_uuid = UUID.uuid4()

      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500})
      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC456", initial_balance: 100})

      CommandAuditMiddleware.reset()

      :ok = BankRouter.dispatch(%TransferMoney{transfer_uuid: transfer_uuid, debit_account: "ACC123", credit_account: "ACC456", amount: 100}, correlation_id: correlation_id)

      assert_receive_event MoneyDeposited, fn event -> assert event.transfer_uuid == transfer_uuid end

      # `correlation_id` should be the same for all commands & events related to money transfer
      assert [correlation_id, correlation_id, correlation_id] =
        CommandAuditMiddleware.dispatched_commands(&(&1.correlation_id))

      event = EventStore.stream_forward(transfer_uuid) |> Enum.at(0)
      assert event.correlation_id == correlation_id
    end
  end

  describe "event handler dispatch command" do
    setup [:start_account_bonus_handler]

    defmodule OpenAccountBonusHandler do
      use Commanded.Event.Handler, name: "OpenAccountBonus"

      def handle(
        %BankAccountOpened{account_number: account_number},
        %{event_id: causation_id, correlation_id: correlation_id})
      do
        deposit_welcome_bonus = %DepositMoney{
          account_number: account_number,
          transfer_uuid: UUID.uuid4(),
          amount: 100,
        }

        BankRouter.dispatch(deposit_welcome_bonus,
          causation_id: causation_id,
          correlation_id: correlation_id,
        )
      end
    end

    test "should copy `correlation_id` from handled event" do
      correlation_id = UUID.uuid4()

      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500}, correlation_id: correlation_id)

      assert_receive_event MoneyDeposited, fn event ->
        assert event.account_number == "ACC123"
        assert event.amount == 100
      end

      money_deposited = EventStore.stream_forward("ACC123") |> Enum.to_list() |> Enum.at(-1)

      assert money_deposited.correlation_id == correlation_id
    end

    test "should copy `causation_id` from handled event" do
      :ok = BankRouter.dispatch(%OpenAccount{account_number: "ACC123", initial_balance: 500})

      assert_receive_event MoneyDeposited, fn event ->
        assert event.account_number == "ACC123"
        assert event.amount == 100
      end

      [account_opened, money_deposited] = EventStore.stream_forward("ACC123") |> Enum.to_list()

      # should set command causation id as handled event id
      [_causation_id, causation_id] = CommandAuditMiddleware.dispatched_commands(&(&1.causation_id))
      assert causation_id == account_opened.event_id

      # should set created event causation id as the command uuid
      [_command_uuid, command_uuid] = CommandAuditMiddleware.dispatched_commands(&(&1.command_uuid))
      assert money_deposited.causation_id == command_uuid
    end

    def start_account_bonus_handler(_context) do
      {:ok, handler} = OpenAccountBonusHandler.start_link()

      on_exit fn ->
        Commanded.Helpers.Process.shutdown(handler)
      end
    end
  end
end
