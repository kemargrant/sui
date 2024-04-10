// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module sui::bridge_tests {
    use sui::address; 
    use sui::balance;
    use sui::coin::{Self, Coin};
    use sui::hex;
    use sui::linked_table::Self;
    use sui::test_scenario;
    use sui::test_utils::destroy;

    use bridge::bridge::{
        assert_not_paused, assert_paused, execute_system_message, 
        get_token_transfer_action_status, inner_limiter, inner_paused, 
        inner_treasury, inner_token_transfer_records, new_bridge_record_for_testing, 
        new_for_testing, send_token, test_execute_emergency_op, 
        test_get_current_seq_num_and_increment, test_execute_update_asset_price, 
        test_execute_update_bridge_limit, test_load_inner_mut, transfer_status_approved,
        transfer_status_claimed, transfer_status_not_found, transfer_status_pending, 
        Bridge,
    };
    use bridge::chain_ids; 
    use bridge::message::{Self, create_blocklist_message};
    use bridge::message_types;
    use bridge::treasury::{BTC, ETH};


    // common error start code for unexpected errors in tests (assertions). 
    // If more than one assert in a test needs to use an unexpected error code,
    // use this as the starting error and add 1 to subsequent errors
    const UNEXPECTED_ERROR: u64 = 10293847; 
    // use on tests that fail to save cleanup
    const TEST_DONE: u64 = 74839201; 

    //
    // Utility functions
    //

    fun freeze_bridge(bridge: &mut Bridge, error: u64) {
        let inner = bridge.test_load_inner_mut();
        // freeze it
        let msg = message::create_emergency_op_message(
            chain_ids::sui_testnet(),
            0, // seq num
            0, // freeze op
        );
        let payload = msg.extract_emergency_op_payload();
        inner.test_execute_emergency_op(payload);
        inner.assert_paused(error);
    }

    fun unfreeze_bridge(bridge: &mut Bridge, error: u64) {
        let inner = bridge.test_load_inner_mut();
        // unfreeze it
        let msg = message::create_emergency_op_message(
            chain_ids::sui_testnet(),
            1, // seq num, this is supposed to be the next seq num but it's not what we test here
            1, // unfreeze op
        );
        let payload = msg.extract_emergency_op_payload();
        inner.test_execute_emergency_op(payload);
        inner.assert_not_paused(error);
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EUnexpectedChainID)]
    fun test_system_msg_incorrect_chain_id() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let blocklist = create_blocklist_message(chain_ids::sui_mainnet(), 0, 0, vector[]);
        bridge.execute_system_message(blocklist, vector[]);

        abort TEST_DONE
    }

    #[test]
    fun test_get_seq_num_and_increment() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);

        let inner = bridge.test_load_inner_mut();
        assert!(
            inner.test_get_current_seq_num_and_increment(
                message_types::committee_blocklist(),
            ) == 0,
            UNEXPECTED_ERROR,
        );
        assert!(
            inner.sequence_nums()[&message_types::committee_blocklist()] == 1,
            UNEXPECTED_ERROR + 1,
        );
        assert!(
            inner.test_get_current_seq_num_and_increment(
                message_types::committee_blocklist(),
            ) == 1,
            UNEXPECTED_ERROR + 2,
        );
        // other message type nonce does not change
        assert!(
            !inner.sequence_nums().contains(&message_types::token()), 
            UNEXPECTED_ERROR + 3,
        );
        assert!(
            !inner.sequence_nums().contains(&message_types::emergency_op()), 
            UNEXPECTED_ERROR + 4,
        );
        assert!(
            !inner.sequence_nums().contains(&message_types::update_bridge_limit()), 
            UNEXPECTED_ERROR + 5,
        );
        assert!(
            !inner.sequence_nums().contains(&message_types::update_asset_price()), 
            UNEXPECTED_ERROR + 6,
        );
        assert!(
            inner.test_get_current_seq_num_and_increment(message_types::token()) == 0,
            UNEXPECTED_ERROR + 7,
        );
        assert!(
            inner.test_get_current_seq_num_and_increment(
                message_types::emergency_op(),
            ) == 0,
            UNEXPECTED_ERROR + 8,
        );
        assert!(
            inner.test_get_current_seq_num_and_increment(
                message_types::update_bridge_limit(),
            ) == 0,
            UNEXPECTED_ERROR + 6,
        );
        assert!(
            inner.test_get_current_seq_num_and_increment(
                message_types::update_asset_price(),
            ) == 0,
            UNEXPECTED_ERROR + 7,
        );

        destroy(bridge);
        scenario.end();
    }

    #[test]
    fun test_update_limit() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_mainnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let inner = bridge.test_load_inner_mut();

        // Assert the starting limit is a different value
        assert!(
            inner.inner_limiter().get_route_limit(
                &chain_ids::get_route(
                    chain_ids::eth_mainnet(), 
                    chain_ids::sui_mainnet(),
                ),
            ) != 1, 
            UNEXPECTED_ERROR,
        );
        // now shrink to 1 for SUI mainnet -> ETH mainnet
        let msg = message::create_update_bridge_limit_message(
            chain_ids::sui_mainnet(), // receiving_chain
            0,
            chain_ids::eth_mainnet(), // sending_chain
            1,
        );
        let payload = msg.extract_update_bridge_limit();
        inner.test_execute_update_bridge_limit(payload);

        // should be 1 now
        assert!(
            inner.inner_limiter().get_route_limit(
                &chain_ids::get_route(
                    chain_ids::eth_mainnet(), 
                    chain_ids::sui_mainnet()
                ),
            ) == 1, 
            UNEXPECTED_ERROR + 1,
        );
        // other routes are not impacted
        assert!(
            inner.inner_limiter().get_route_limit(
                &chain_ids::get_route(
                    chain_ids::eth_sepolia(), 
                    chain_ids::sui_testnet(),
                ),
            ) != 1, 
            UNEXPECTED_ERROR + 2,
        );

        destroy(bridge);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EUnexpectedChainID)]
    fun test_execute_update_bridge_limit_abort_with_unexpected_chain_id() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let inner = bridge.test_load_inner_mut();

        // shrink to 1 for SUI mainnet -> ETH mainnet
        let msg = message::create_update_bridge_limit_message(
            chain_ids::sui_mainnet(), // receiving_chain
            0,
            chain_ids::eth_mainnet(), // sending_chain
            1,
        );
        let payload = msg.extract_update_bridge_limit();
        // This abort because the receiving_chain (sui_mainnet) is not the same as
        // the bridge's chain_id (sui_devnet)
        inner.test_execute_update_bridge_limit(payload);

        abort TEST_DONE
    }


    #[test]
    fun test_update_asset_price() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let inner = bridge.test_load_inner_mut();

        // Assert the starting limit is a different value
        assert!(
            inner.inner_treasury().notional_value<BTC>() != 1_001_000_000, 
            UNEXPECTED_ERROR,
        );
        // now change it to 100_001_000
        let msg = message::create_update_asset_price_message(
            inner.inner_treasury().token_id<BTC>(),
            chain_ids::sui_mainnet(),
            0,
            1_001_000_000,
        );
        let payload = msg.extract_update_asset_price();
        inner.test_execute_update_asset_price(payload);

        // should be 1_001_000_000 now
        assert!(
            inner.inner_treasury().notional_value<BTC>() == 1_001_000_000,
            UNEXPECTED_ERROR + 1,
        );
        // other assets are not impacted
        assert!(
            inner.inner_treasury().notional_value<ETH>() != 1_001_000_000, 
            UNEXPECTED_ERROR + 2,
        );

        destroy(bridge);
        scenario.end();
    }

    #[test]
    fun test_test_execute_emergency_op() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);

        assert!(!bridge.test_load_inner_mut().inner_paused(), UNEXPECTED_ERROR);
        freeze_bridge(&mut bridge, UNEXPECTED_ERROR + 1);

        assert!(bridge.test_load_inner_mut().inner_paused(), UNEXPECTED_ERROR + 2);
        unfreeze_bridge(&mut bridge, UNEXPECTED_ERROR + 3);

        destroy(bridge);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EBridgeNotPaused)]
    fun test_test_execute_emergency_op_abort_when_not_frozen() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);

        assert!(!bridge.test_load_inner_mut().inner_paused(), UNEXPECTED_ERROR);
        // unfreeze it, should abort
        unfreeze_bridge(&mut bridge, UNEXPECTED_ERROR + 1);

        abort TEST_DONE
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EBridgeUnavailable)]
    fun test_execute_send_token_frozen() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);

        assert!(!bridge.test_load_inner_mut().inner_paused(), UNEXPECTED_ERROR);
        freeze_bridge(&mut bridge, UNEXPECTED_ERROR + 1);

        let eth_address = b"01234"; // it does not really matter
        let btc: Coin<BTC> = coin::mint_for_testing<BTC>(1, ctx);
        bridge.send_token(
            chain_ids::eth_sepolia(), 
            eth_address,
            btc,
            ctx,
        );

        abort TEST_DONE
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EInvalidBridgeRoute)]
    fun test_execute_send_token_invalid_route() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);

        let eth_address = b"01234"; // it does not really matter
        let btc: Coin<BTC> = coin::mint_for_testing<BTC>(1, ctx);
        bridge.send_token(
            chain_ids::eth_mainnet(), 
            eth_address,
            btc,
            ctx,
        );

        abort TEST_DONE
    }

    #[test]
    #[expected_failure(abort_code = bridge::bridge::EBridgeAlreadyPaused)]
    fun test_test_execute_emergency_op_abort_when_already_frozen() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let inner = bridge.test_load_inner_mut();

        // initially it's unfrozen
        assert!(!inner.inner_paused(), UNEXPECTED_ERROR);
        // freeze it
        let msg = message::create_emergency_op_message(
            chain_ids::sui_testnet(),
            0, // seq num
            0, // freeze op
        );
        let payload = msg.extract_emergency_op_payload();
        inner.test_execute_emergency_op(payload);

        // should be frozen now
        assert!(inner.inner_paused(), UNEXPECTED_ERROR + 1);

        // freeze it again, should abort
        let msg = message::create_emergency_op_message(
            chain_ids::sui_testnet(),
            1, // seq num, should be the next seq num but it's not what we test here
            0, // unfreeze op
        );
        let payload = msg.extract_emergency_op_payload();
        inner.test_execute_emergency_op(payload);

        abort TEST_DONE
    }

    #[test]
    fun test_get_token_transfer_action_status() {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = scenario.ctx();
        let chain_id = chain_ids::sui_testnet();
        let mut bridge = new_for_testing(ctx, chain_id);
        let coin = coin::mint_for_testing<ETH>(12345, ctx);

        // Test when pending
        let message = message::create_token_bridge_message(
            chain_ids::sui_testnet(), // source chain
            10, // seq_num
            address::to_bytes(ctx.sender()), // sender address
            chain_ids::eth_sepolia(), // target_chain
            hex::decode(b"00000000000000000000000000000000000000c8"), // target_address
            1u8, // token_type
            coin.balance().value(),
        );

        let key = message.key();
        linked_table::push_back(
            bridge.test_load_inner_mut().inner_token_transfer_records(), 
            key, 
            new_bridge_record_for_testing(message, option::none(), false),
        );
        assert!(
            bridge.get_token_transfer_action_status(chain_id, 10)
                == transfer_status_pending(),
            UNEXPECTED_ERROR,
        );

        // Test when ready for claim
        let message = message::create_token_bridge_message(
            chain_ids::sui_testnet(), // source chain
            11, // seq_num
            address::to_bytes(ctx.sender()), // sender address
            chain_ids::eth_sepolia(), // target_chain
            hex::decode(b"00000000000000000000000000000000000000c8"), // target_address
            1u8, // token_type
            balance::value(coin::balance(&coin))
        );
        let key = message.key();
        bridge.test_load_inner_mut().inner_token_transfer_records().push_back(
            key, 
            new_bridge_record_for_testing(message, option::some(vector[]), false),
        );
        assert!(
            bridge.get_token_transfer_action_status(chain_id, 11)
                == transfer_status_approved(),
            UNEXPECTED_ERROR + 1,
        );

        // Test when already claimed
        let message = message::create_token_bridge_message(
            chain_ids::sui_testnet(), // source chain
            12, // seq_num
            address::to_bytes(ctx.sender()), // sender address
            chain_ids::eth_sepolia(), // target_chain
            hex::decode(b"00000000000000000000000000000000000000c8"), // target_address
            1u8, // token_type
            balance::value(coin::balance(&coin))
        );
        let key = message.key();
        bridge.test_load_inner_mut().inner_token_transfer_records().push_back(
            key, 
            new_bridge_record_for_testing(message, option::some(vector[]), true),
        );
        assert!(
            bridge.get_token_transfer_action_status(chain_id, 12)
                == transfer_status_claimed(),
            UNEXPECTED_ERROR + 2,
        );

        // Test when message not found
        assert!(
            bridge.get_token_transfer_action_status(chain_id, 13)
                == transfer_status_not_found(),
            UNEXPECTED_ERROR + 3,
        );

        destroy(bridge);
        coin.burn_for_testing();
        scenario.end();
    }
}

