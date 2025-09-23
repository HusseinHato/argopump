#[test_only]
module BullPump::bonding_curve_tests {
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
    use std::vector;

    // Test constants
    const INITIAL_APT_BALANCE: u64 = 1000_00000000; // 1000 APT
    const SMALL_BUY_AMOUNT: u64 = 1_00000000; // 1 APT
    const MEDIUM_BUY_AMOUNT: u64 = 10_00000000; // 10 APT
    const LARGE_BUY_AMOUNT: u64 = 100_00000000; // 100 APT

    // Helper function to setup test environment
    fun setup_test_env(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ): address {
        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Initialize token factory
        // token_factory::init_module(admin); // Removed because init_module is private and not accessible
        
        // Setup user account
        let user_addr = signer::address_of(user);
        account::create_account_for_test(user_addr);
        coin::register<aptos_coin::AptosCoin>(user);
        aptos_coin::mint(aptos_framework, user_addr, INITIAL_APT_BALANCE);
        
        // Create a test token
        token_factory::create_fa(
            admin,
            string::utf8(b"TestToken"),
            string::utf8(b"TEST"),
            string::utf8(b"https://test.icon"),
            string::utf8(b"https://test.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[registry.length() - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        
        fa_address
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_buy_tokens_basic(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        // Get initial balances
        let initial_apt_balance = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        let initial_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let initial_apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Buy tokens
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY_AMOUNT);
        
        // Check balances after purchase
        let final_apt_balance = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        let final_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let final_apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Assertions
        assert!(final_apt_balance < initial_apt_balance, 1); // APT should decrease
        assert!(final_token_balance > initial_token_balance, 2); // Tokens should increase
        assert!(final_apt_reserves > initial_apt_reserves, 3); // Pool reserves should increase
        
        debug::print(&string::utf8(b"=== Buy Tokens Basic Test ==="));
        debug::print(&string::utf8(b"Initial APT balance: "));
        debug::print(&initial_apt_balance);
        debug::print(&string::utf8(b"Final APT balance: "));
        debug::print(&final_apt_balance);
        debug::print(&string::utf8(b"Tokens received: "));
        debug::print(&final_token_balance);
        debug::print(&string::utf8(b"APT reserves: "));
        debug::print(&final_apt_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_sell_tokens_basic(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        // First buy some tokens
        bonding_curve_pool::buy_tokens(alice, fa_address, MEDIUM_BUY_AMOUNT);
        
        let tokens_bought = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let apt_balance_after_buy = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        let apt_reserves_after_buy = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Sell half of the tokens
        let tokens_to_sell = tokens_bought / 2;
        bonding_curve_pool::sell_tokens(alice, fa_address, tokens_to_sell);
        
        let final_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let final_apt_balance = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        let final_apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Assertions
        assert!(final_token_balance < tokens_bought, 1); // Token balance should decrease
        assert!(final_apt_balance > apt_balance_after_buy, 2); // APT balance should increase
        assert!(final_apt_reserves < apt_reserves_after_buy, 3); // Pool reserves should decrease
        
        debug::print(&string::utf8(b"=== Sell Tokens Basic Test ==="));
        debug::print(&string::utf8(b"Tokens bought: "));
        debug::print(&tokens_bought);
        debug::print(&string::utf8(b"Tokens sold: "));
        debug::print(&tokens_to_sell);
        debug::print(&string::utf8(b"Final token balance: "));
        debug::print(&final_token_balance);
        debug::print(&string::utf8(b"APT received from sell: "));
        debug::print(&(final_apt_balance - apt_balance_after_buy));
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_bonding_curve_math(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        // Test multiple purchases to verify bonding curve behavior
        let purchase_amounts = vector[1_00000000, 2_00000000, 5_00000000, 10_00000000];
        let i = 0;
        
        while (i < vector::length(&purchase_amounts)) {
            let amount = *vector::borrow(&purchase_amounts, i);
            let initial_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
            
            bonding_curve_pool::buy_tokens(alice, fa_address, amount);
            
            let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
            let tokens_received = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
            
            debug::print(&string::utf8(b"=== Bonding Curve Math Test ==="));
            debug::print(&string::utf8(b"Purchase amount: "));
            debug::print(&amount);
            debug::print(&string::utf8(b"Reserves increase: "));
            debug::print(&(final_reserves - initial_reserves));
            debug::print(&string::utf8(b"Total tokens received: "));
            debug::print(&tokens_received);
            
            // Verify that reserves increased by less than the full purchase amount (due to fees)
            assert!(final_reserves - initial_reserves < amount, 1);
            
            i = i + 1;
        };
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2, bob = @0x3)]
    fun test_multiple_users(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer,
        bob: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        
        // Setup Bob
        let bob_addr = signer::address_of(bob);
        account::create_account_for_test(bob_addr);
        coin::register<aptos_coin::AptosCoin>(bob);
        aptos_coin::mint(aptos_framework, bob_addr, INITIAL_APT_BALANCE);
        
        // Both users buy tokens
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY_AMOUNT);
        bonding_curve_pool::buy_tokens(bob, fa_address, SMALL_BUY_AMOUNT);
        
        let alice_tokens = bonding_curve_pool::get_token_balance(signer::address_of(alice), fa_address);
        let bob_tokens = bonding_curve_pool::get_token_balance(bob_addr, fa_address);
        
        // Due to bonding curve, Bob should receive fewer tokens than Alice (same APT amount, higher price)
        assert!(alice_tokens > bob_tokens, 1);
        
        debug::print(&string::utf8(b"=== Multiple Users Test ==="));
        debug::print(&string::utf8(b"Alice tokens: "));
        debug::print(&alice_tokens);
        debug::print(&string::utf8(b"Bob tokens: "));
        debug::print(&bob_tokens);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_fee_calculation(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        let initial_treasury_balance = coin::balance<aptos_coin::AptosCoin>(@BullPump);
        let initial_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        bonding_curve_pool::buy_tokens(alice, fa_address, MEDIUM_BUY_AMOUNT);
        
        let final_treasury_balance = coin::balance<aptos_coin::AptosCoin>(@BullPump);
        let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        let fee_collected = final_treasury_balance - initial_treasury_balance;
        let reserves_increase = final_reserves - initial_reserves;
        
        // Verify fee calculation (0.1% = 100 basis points)
        let expected_fee = MEDIUM_BUY_AMOUNT * 100 / 10000; // 0.1%
        assert!(fee_collected == expected_fee, 1);
        
        // Verify that reserves + fee = total amount paid
        assert!(reserves_increase + fee_collected == MEDIUM_BUY_AMOUNT, 2);
        
        debug::print(&string::utf8(b"=== Fee Calculation Test ==="));
        debug::print(&string::utf8(b"Amount paid: "));
        debug::print(&MEDIUM_BUY_AMOUNT);
        debug::print(&string::utf8(b"Fee collected: "));
        debug::print(&fee_collected);
        debug::print(&string::utf8(b"Reserves increase: "));
        debug::print(&reserves_increase);
        debug::print(&string::utf8(b"Expected fee: "));
        debug::print(&expected_fee);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    #[expected_failure(abort_code = 4)] // EZERO_INPUT_AMOUNT
    fun test_buy_zero_amount_fails(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        bonding_curve_pool::buy_tokens(alice, fa_address, 0);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    #[expected_failure(abort_code = 4)] // EZERO_INPUT_AMOUNT
    fun test_sell_zero_amount_fails(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        bonding_curve_pool::sell_tokens(alice, fa_address, 0);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    #[expected_failure(abort_code = 2)] // EPOOL_NOT_FOUND
    fun test_buy_nonexistent_pool_fails(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        setup_test_env(aptos_framework, admin, alice);
        // Try to buy from a non-existent pool
        bonding_curve_pool::buy_tokens(alice, @0x999, SMALL_BUY_AMOUNT);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_round_trip_buy_sell(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        let initial_apt_balance = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        
        // Buy tokens
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY_AMOUNT);
        let tokens_bought = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        
        // Sell all tokens back
        bonding_curve_pool::sell_tokens(alice, fa_address, tokens_bought);
        let final_apt_balance = coin::balance<aptos_coin::AptosCoin>(alice_addr);
        
        // Due to fees and bonding curve mechanics, final balance should be less than initial
        assert!(final_apt_balance < initial_apt_balance, 1);
        
        // Should have no tokens left
        let final_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        assert!(final_token_balance == 0, 2);
        
        debug::print(&string::utf8(b"=== Round Trip Test ==="));
        debug::print(&string::utf8(b"Initial APT: "));
        debug::print(&initial_apt_balance);
        debug::print(&string::utf8(b"Final APT: "));
        debug::print(&final_apt_balance);
        debug::print(&string::utf8(b"Net loss: "));
        debug::print(&(initial_apt_balance - final_apt_balance));
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, whale = @0x2)]
    fun test_graduation_threshold(
        aptos_framework: &signer,
        admin: &signer,
        whale: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, whale);
        let whale_addr = signer::address_of(whale);
        
        // Give whale a lot of APT
        aptos_coin::mint(aptos_framework, whale_addr, 25000_00000000); // 25000 APT
        
        // Buy enough to reach graduation threshold (21500 APT)
        let large_purchase = 22000_00000000; // 22000 APT to ensure graduation
        bonding_curve_pool::buy_tokens(whale, fa_address, large_purchase);
        
        let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        debug::print(&string::utf8(b"=== Graduation Test ==="));
        debug::print(&string::utf8(b"Final reserves: "));
        debug::print(&final_reserves);
        debug::print(&string::utf8(b"Graduation threshold: "));
        debug::print(&21500_00000000);
        
        // Pool should have graduated
        assert!(final_reserves >= 21500_00000000, 1);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2)]
    fun test_view_functions(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer
    ) {
        let fa_address = setup_test_env(aptos_framework, admin, alice);
        let alice_addr = signer::address_of(alice);
        
        // Test initial state
        let initial_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let initial_apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        assert!(initial_token_balance == 0, 1);
        assert!(initial_apt_reserves == 0, 2);
        
        // Buy some tokens and test again
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY_AMOUNT);
        
        let final_token_balance = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let final_apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        assert!(final_token_balance > 0, 3);
        assert!(final_apt_reserves > 0, 4);
        
        debug::print(&string::utf8(b"=== View Functions Test ==="));
        debug::print(&string::utf8(b"Token balance: "));
        debug::print(&final_token_balance);
        debug::print(&string::utf8(b"APT reserves: "));
        debug::print(&final_apt_reserves);
    }
}
