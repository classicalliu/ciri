# frozen_string_literal: true

# Copyright (c) 2018 by Jiang Jinyang <jjyruby@gmail.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


require 'forwardable'
require 'ciri/forks'
require 'ciri/core_ext'
require 'ciri/utils'
require 'ciri/types/account'
require 'ciri/types/receipt'
require_relative 'evm/op'
require_relative 'evm/vm'
require_relative 'evm/errors'
require_relative 'evm/execution_context'

using Ciri::CoreExt

module Ciri
  class EVM
    include Utils::Logger
    extend Forwardable

    ExecutionResult = Struct.new(:status, :state_root, :logs, :gas_used, :gas_price, :exception, :output, keyword_init: true) do
      def logs_hash
        # return nil unless vm
        Utils.keccak(RLP.encode_simple(logs))
      end
    end

    def_delegators :@state, :find_account, :account_dead?, :get_account_code, :state_root

    attr_reader :state, :fork_schema

    def initialize(state:, chain: nil, fork_schema: Ciri::Forks::Frontier::Schema.new)
      @state = state
      @fork_schema = fork_schema
      @chain = chain
    end

    # transition block
    def transition(block, check_gas_limit: true, check_gas_used: true)
      receipts = []

      total_gas_used = 0
      # execute transactions, we don't need to valid transactions, it should be done before evm(in Chain module).
      block.transactions.each do |transaction|
        result = execute_transaction(transaction, header: block.header, ignore_exception: true)

        total_gas_used += result.gas_used
        if check_gas_limit && total_gas_used > block.header.gas_limit
          raise InvalidTransition.new('reach block gas_limit')
        end
        if check_gas_used && total_gas_used > block.header.gas_used
          raise InvalidTransition.new("overflow header gas_used, total_gas_used: #{total_gas_used}, block gas_used: #{block.header.gas_used}")
        end

        receipt = fork_schema.make_receipt(execution_result: result, gas_used: total_gas_used)
        receipts << receipt
      end

      if check_gas_used && total_gas_used != block.header.gas_used
        raise InvalidTransition.new("incorrect gas_used, actual used: #{total_gas_used} header: #{block.header.gas_used}")
      end

      rewards = fork_schema.mining_rewards_of_block(block)

      # apply rewards
      rewards.each do |address, value|
        if value > 0
          account = find_account(address)
          account.balance += value
          state.set_balance(address, account.balance)
        end
      end

      receipts
    end

    # execute transaction
    # @param t Transaction
    # @param header Chain::Header
    def execute_transaction(t, header: nil, block_info: nil, ignore_exception: false)
      unless state.find_account(t.sender).balance >= t.gas_price * t.gas_limit + t.value
        raise InvalidTransaction.new('account balance not enough')
      end

      # remove gas fee from account balance
      state.add_balance(t.sender, -1 * t.gas_limit * t.gas_price)

      intrinsic_gas = fork_schema.intrinsic_gas_of_transaction(t)
      if intrinsic_gas > t.gas_limit
        raise InvalidTransaction.new('intrinsic gas overflowed gas limit')
      end

      gas_limit = t.gas_limit - intrinsic_gas

      instruction = Instruction.new(
        origin: t.sender,
        price: t.gas_price,
        sender: t.sender,
        value: t.value,
        header: header,
      )

      if t.contract_creation?
        instruction.bytes_code = t.data
      else
        instruction.bytes_code = get_account_code(t.to)
        instruction.address = t.to
        instruction.data = t.data
      end

      block_info ||= header && BlockInfo.from_header(header)
      context = Ciri::EVM::ExecutionContext.new(
        instruction: instruction, gas_limit: gas_limit,
        block_info: block_info, fork_schema: fork_schema
      )
      vm = Ciri::EVM::VM.new(state: state, chain: @chain, burn_gas_on_exception: true)

      unless instruction.value > state.find_account(instruction.sender).balance
        state.increment_nonce(instruction.sender)
      end

      vm.with_context(context) do
        if t.contract_creation?
          # contract creation
          vm.create_contract(context: context)
        else
          vm.call_message(context: context)
        end
        raise context.exception if !ignore_exception && context.exception

        # refund gas
        sub_state_refund_gas = fork_schema.calculate_refund_gas(vm)
        context.refund_gas(sub_state_refund_gas)
        refund_gas = context.reset_refund_gas
        remain_gas = context.remain_gas
        actually_gas_used = t.gas_limit - remain_gas
        actually_refund_gas = [refund_gas, actually_gas_used / 2].min
        refund_gas_amount = (actually_refund_gas + remain_gas) * t.gas_price
        debug("Transaction refund #{refund_gas_amount} to #{t.sender.to_s.to_hex}")
        state.add_balance(t.sender, refund_gas_amount)

        # gas_used after refund gas
        gas_used = actually_gas_used - actually_refund_gas

        # miner fee
        fee = gas_used * t.gas_price
        debug("Transaction fee #{fee}")
        miner_account = find_account(block_info.coinbase)
        miner_account.balance += fee
        state.set_balance(block_info.coinbase, miner_account.balance)

        # EIP158 fork, we need to delete miner account if account become empty
        vm.sub_state.add_touched_account(block_info.coinbase)
        vm.delete_empty_accounts

        # destroy accounts
        vm.execution_context.all_suicide_accounts.each do |address|
          state.set_balance(address, 0)
          state.delete_account(address)
        end

        ExecutionResult.new(status: context.status, state_root: state_root, logs: context.all_log_series,
                            gas_used: gas_used, gas_price: t.gas_price, exception: context.exception,
                            output: context.output)
      end
    end

  end
end
