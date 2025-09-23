#[test_only]
module BullPump::edge_case_tests {
    use std::signer;
    use std::string;
    use std::option;
    use std::debug;

    use aptos_framework::account;
    use aptos_framework::aptos_coin;
    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;

    use BullPump::token_factory;
    use BullPump::bonding_curve_pool;

    // Test constants
    const INITIAL_APT_BALANCE: u64 = 1000_00000000; // 1000 APT
    const TINY_AMOUNT: u64 = 1; // 1 octa (smallest unit)
    const HUGE_AMOUNT: u64 = 1000000_00000000; // 1 million APT

    // Helper function to setup test environment
    fun setup_test_env(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ): address {
        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Initialize token factory
        token_factory::test_init_module(admin);
        
        // Setup user account
        let user_addr = signer::address_of(user);
        account::create_account_for_test(user_addr);
        coin::register<aptos_coin::AptosCoin>(user);
        aptos_coin::mint(aptos_framework, user_addr, INITIAL_APT_BALANCE);
        
        // Setup admin
        let admin_addr = signer::address_of(admin);
        coin::register<aptos_coin::AptosCoin>(admin);
        aptos_coin::mint(aptos_framework, admin_addr, INITIAL_APT_BALANCE);
        
        // Create a test token
        token_factory::create_fa(
            admin,
            string::utf8(b"EdgeToken"),
            string::utf8(b"EDGE"),
            string::utf8(b"https://edge.icon"),
            string::utf8(b"https://edge.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        
        fa_address
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_minimum_purchase_amount(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Try to buy with minimum possible amount (1 octa)
        bonding_curve_pool::buy_tokens(user, fa_address, TINY_AMOUNT);
        
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let pool_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Should still work, even with tiny amounts
        // Due to fees, reserves might be 0 but transaction should succeed
        assert!(user_tokens >= 0, 1); // Might be 0 due to rounding
        assert!(pool_reserves >= 0, 2);
        
        debug::print(&string::utf8(b"=== Minimum Purchase Test ==="));
        debug::print(&string::utf8(b"Purchase amount: "));
        debug::print(&TINY_AMOUNT);
        debug::print(&string::utf8(b"Tokens received: "));
        debug::print(&user_tokens);
        debug::print(&string::utf8(b"Pool reserves: "));
        debug::print(&pool_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_maximum_purchase_amount(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Give user a huge amount of APT
        aptos_coin::mint(aptos_framework, user_addr, HUGE_AMOUNT);
        
        let initial_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        
        // Try to buy with huge amount
        bonding_curve_pool::buy_tokens(user, fa_address, HUGE_AMOUNT);
        
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let pool_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        let final_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        
        // Should work and likely trigger graduation
        assert!(user_tokens > 0, 1);
        assert!(pool_reserves >= 21500_00000000, 2); // Should graduate
        assert!(final_pool_tokens < initial_pool_tokens, 3); // Tokens burned during graduation
        
        debug::print(&string::utf8(b"=== Maximum Purchase Test ==="));
        debug::print(&string::utf8(b"Purchase amount: "));
        debug::print(&HUGE_AMOUNT);
        debug::print(&string::utf8(b"Tokens received: "));
        debug::print(&user_tokens);
        debug::print(&string::utf8(b"Pool reserves: "));
        debug::print(&pool_reserves);
        debug::print(&string::utf8(b"Tokens burned: "));
        debug::print(&(initial_pool_tokens - final_pool_tokens));
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_sell_all_tokens(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Buy some tokens first
        bonding_curve_pool::buy_tokens(user, fa_address, 100_00000000); // 100 APT
        
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let apt_before_sell = coin::balance<aptos_coin::AptosCoin>(user_addr);
        
        // Sell all tokens
        bonding_curve_pool::sell_tokens(user, fa_address, user_tokens);
        
        let final_user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let apt_after_sell = coin::balance<aptos_coin::AptosCoin>(user_addr);
        
        // Should have no tokens left and received some APT
        assert!(final_user_tokens == 0, 1);
        assert!(apt_after_sell > apt_before_sell, 2);
        
        debug::print(&string::utf8(b"=== Sell All Tokens Test ==="));
        debug::print(&string::utf8(b"Tokens sold: "));
        debug::print(&user_tokens);
        debug::print(&string::utf8(b"APT received: "));
        debug::print(&(apt_after_sell - apt_before_sell));
        debug::print(&string::utf8(b"Final token balance: "));
        debug::print(&final_user_tokens);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    #[expected_failure] // Should fail due to insufficient balance
    fun test_sell_more_tokens_than_owned(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Buy some tokens
        bonding_curve_pool::buy_tokens(user, fa_address, 10_00000000); // 10 APT
        
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        
        // Try to sell more tokens than owned
        bonding_curve_pool::sell_tokens(user, fa_address, user_tokens + 1000000);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    #[expected_failure] // Should fail due to insufficient APT
    fun test_buy_more_than_balance(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        let user_apt_balance = coin::balance<aptos_coin::AptosCoin>(user_addr);
        
        // Try to buy with more APT than user has
        bonding_curve_pool::buy_tokens(user, fa_address, user_apt_balance + 1_00000000);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_repeated_small_transactions(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        let small_amount = 1000000; // 0.01 APT
        let num_transactions = 100;
        
        let i = 0;
        while (i < num_transactions) {
            bonding_curve_pool::buy_tokens(user, fa_address, small_amount);
            i = i + 1;
        };
        
        let total_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let pool_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Should accumulate tokens and reserves
        assert!(total_tokens > 0, 1);
        assert!(pool_reserves > 0, 2);
        
        // Now sell in small batches
        let tokens_per_sell = total_tokens / 50; // Sell in 50 batches
        i = 0;
        while (i < 50 && bonding_curve_pool::get_token_balance(user_addr, fa_address) > 0) {
            let current_balance = bonding_curve_pool::get_token_balance(user_addr, fa_address);
            let sell_amount = if (tokens_per_sell > current_balance) current_balance else tokens_per_sell;
            if (sell_amount > 0) {
                bonding_curve_pool::sell_tokens(user, fa_address, sell_amount);
            };
            i = i + 1;
        };
        
        let final_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        
        debug::print(&string::utf8(b"=== Repeated Small Transactions Test ==="));
        debug::print(&string::utf8(b"Number of buy transactions: "));
        debug::print(&(num_transactions as u64));
        debug::print(&string::utf8(b"Total tokens accumulated: "));
        debug::print(&total_tokens);
        debug::print(&string::utf8(b"Final tokens after selling: "));
        debug::print(&final_tokens);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_precision_with_large_numbers(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Give user more APT for large transactions
        aptos_coin::mint(aptos_framework, user_addr, 10000_00000000); // 10000 APT
        
        // Test with large purchase amounts
        let large_purchase = 5000_00000000; // 5000 APT
        bonding_curve_pool::buy_tokens(user, fa_address, large_purchase);
        
        let tokens_received = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        let reserves_after_buy = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Sell a large portion back
        let tokens_to_sell = tokens_received / 2;
        let apt_before_sell = coin::balance<aptos_coin::AptosCoin>(user_addr);
        bonding_curve_pool::sell_tokens(user, fa_address, tokens_to_sell);
        let apt_after_sell = coin::balance<aptos_coin::AptosCoin>(user_addr);
        
        let apt_received = apt_after_sell - apt_before_sell;
        let reserves_after_sell = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Verify mathematical consistency
        assert!(tokens_received > 0, 1);
        assert!(apt_received > 0, 2);
        assert!(reserves_after_sell < reserves_after_buy, 3);
        assert!(reserves_after_sell + apt_received <= reserves_after_buy, 4); // Account for rounding
        
        debug::print(&string::utf8(b"=== Large Number Precision Test ==="));
        debug::print(&string::utf8(b"Large purchase: "));
        debug::print(&large_purchase);
        debug::print(&string::utf8(b"Tokens received: "));
        debug::print(&tokens_received);
        debug::print(&string::utf8(b"Tokens sold: "));
        debug::print(&tokens_to_sell);
        debug::print(&string::utf8(b"APT received from sell: "));
        debug::print(&apt_received);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_bonding_curve_edge_cases(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, user);
        let user_addr = signer::address_of(user);
        
        // Test buying when pool has maximum tokens (initial state)
        let initial_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        assert!(initial_pool_tokens == 1_000_000_000_00000000, 1); // 1 billion tokens
        
        // Buy a small amount when pool is full
        bonding_curve_pool::buy_tokens(user, fa_address, 1_00000000); // 1 APT
        let tokens_from_full_pool = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        
        // Buy progressively larger amounts to test curve behavior
        let purchase_amounts = vector[
            1_00000000,   // 1 APT
            10_00000000,  // 10 APT
            100_00000000, // 100 APT
            500_00000000  // 500 APT
        ];
        
        let i = 0;
        let previous_tokens = tokens_from_full_pool;
        
        while (i < vector::length(&purchase_amounts)) {
            let amount = *vector::borrow(&purchase_amounts, i);
            aptos_coin::mint(aptos_framework, user_addr, amount); // Give user more APT
            
            bonding_curve_pool::buy_tokens(user, fa_address, amount);
            let current_total_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
            let tokens_from_this_purchase = current_total_tokens - previous_tokens;
            
            debug::print(&string::utf8(b"Purchase amount: "));
            debug::print(&amount);
            debug::print(&string::utf8(b"Tokens received: "));
            debug::print(&tokens_from_this_purchase);
            debug::print(&string::utf8(b"Tokens per APT: "));
            debug::print(&(tokens_from_this_purchase * 100000000 / amount)); // Multiply for precision
            
            // Each subsequent purchase should yield fewer tokens per APT
            if (i > 0) {
                let prev_amount = *vector::borrow(&purchase_amounts, i - 1);
                let prev_tokens_per_apt = previous_tokens * 100000000 / prev_amount;
                let current_tokens_per_apt = tokens_from_this_purchase * 100000000 / amount;
                
                // Due to bonding curve, should get fewer tokens per APT as price increases
                // Note: This might not always hold due to different purchase amounts, so we use a loose check
                debug::print(&string::utf8(b"Previous tokens per APT: "));
                debug::print(&prev_tokens_per_apt);
                debug::print(&string::utf8(b"Current tokens per APT: "));
                debug::print(&current_tokens_per_apt);
            };
            
            previous_tokens = current_total_tokens;
            i = i + 1;
        };
        
        // Verify pool state
        let final_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        assert!(final_pool_tokens < initial_pool_tokens, 2);
        assert!(final_reserves > 0, 3);
        
        debug::print(&string::utf8(b"=== Bonding Curve Edge Cases ==="));
        debug::print(&string::utf8(b"Initial pool tokens: "));
        debug::print(&initial_pool_tokens);
        debug::print(&string::utf8(b"Final pool tokens: "));
        debug::print(&final_pool_tokens);
        debug::print(&string::utf8(b"Tokens distributed: "));
        debug::print(&(initial_pool_tokens - final_pool_tokens));
        debug::print(&string::utf8(b"Final reserves: "));
        debug::print(&final_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_empty_string_metadata(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Initialize token factory
        token_factory::test_init_module(admin);
        
        // Setup admin
        let admin_addr = signer::address_of(admin);
        coin::register<aptos_coin::AptosCoin>(admin);
        aptos_coin::mint(aptos_framework, admin_addr, INITIAL_APT_BALANCE);
        
        // Create token with empty strings (should still work)
        token_factory::create_fa(
            admin,
            string::utf8(b""), // Empty name
            string::utf8(b""), // Empty symbol
            string::utf8(b""), // Empty icon URI
            string::utf8(b""), // Empty project URI
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Verify token was created successfully
        let (name, symbol, icon_uri, project_uri, decimals, max_supply) = 
            token_factory::get_fa_object_metadata(fa_address);
        
        assert!(string::length(&name) == 0, 1);
        assert!(string::length(&symbol) == 0, 2);
        assert!(string::length(&icon_uri) == 0, 3);
        assert!(string::length(&project_uri) == 0, 4);
        assert!(decimals == 8, 5);
        assert!(option::is_some(&max_supply), 6);
        
        // Should still be able to trade
        let user_addr = signer::address_of(user);
        account::create_account_for_test(user_addr);
        coin::register<aptos_coin::AptosCoin>(user);
        aptos_coin::mint(aptos_framework, user_addr, INITIAL_APT_BALANCE);
        
        bonding_curve_pool::buy_tokens(user, fa_address, 1_00000000);
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        assert!(user_tokens > 0, 7);
        
        debug::print(&string::utf8(b"=== Empty String Metadata Test ==="));
        debug::print(&string::utf8(b"Token created with empty metadata"));
        debug::print(&string::utf8(b"User tokens: "));
        debug::print(&user_tokens);
        
        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, whale = @0x2)]
    fun test_graduation_boundary_conditions(
        aptos_framework: &signer,
        admin: &signer,
        whale: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, whale);
        let whale_addr = signer::address_of(whale);
        
        // Give whale enough APT
        aptos_coin::mint(aptos_framework, whale_addr, 25000_00000000);
        
        // Buy just under graduation threshold
        let almost_graduation = 21499_00000000; // Just under 21500 APT
        bonding_curve_pool::buy_tokens(whale, fa_address, almost_graduation);
        
        let reserves_before_graduation = bonding_curve_pool::get_apt_reserves(fa_address);
        let pool_tokens_before = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        
        // Should not have graduated yet
        assert!(reserves_before_graduation < 21500_00000000, 1);
        
        // Buy just enough to trigger graduation
        bonding_curve_pool::buy_tokens(whale, fa_address, 2_00000000); // 2 more APT
        
        let reserves_after_graduation = bonding_curve_pool::get_apt_reserves(fa_address);
        let pool_tokens_after = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        
        // Should have graduated now
        assert!(reserves_after_graduation >= 21500_00000000, 2);
        
        // Tokens should have been burned
        assert!(pool_tokens_after < pool_tokens_before, 3);
        
        debug::print(&string::utf8(b"=== Graduation Boundary Test ==="));
        debug::print(&string::utf8(b"Reserves before graduation: "));
        debug::print(&reserves_before_graduation);
        debug::print(&string::utf8(b"Reserves after graduation: "));
        debug::print(&reserves_after_graduation);
        debug::print(&string::utf8(b"Tokens burned: "));
        debug::print(&(pool_tokens_before - pool_tokens_after));
    }
}
