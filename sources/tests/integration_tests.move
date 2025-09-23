#[test_only]
module BullPump::integration_tests {
    use std::signer;
    use std::string;
    use std::option;
    use std::debug;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::aptos_coin;
    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;

    use BullPump::token_factory;
    use BullPump::bonding_curve_pool;

    // Test constants
    const INITIAL_APT_BALANCE: u64 = 10000_00000000; // 10000 APT
    const SMALL_BUY: u64 = 1_00000000; // 1 APT
    const MEDIUM_BUY: u64 = 10_00000000; // 10 APT
    const LARGE_BUY: u64 = 100_00000000; // 100 APT
    const GRADUATION_BUY: u64 = 22000_00000000; // 22000 APT

    // Helper function to setup test environment with multiple users
    fun setup_multi_user_env(
        aptos_framework: &signer,
        admin: &signer,
        users: vector<&signer>
    ) {
        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Initialize token factory
        token_factory::test_init_module(admin);
        
        // Setup admin
        let admin_addr = signer::address_of(admin);
        coin::register<aptos_coin::AptosCoin>(admin);
        aptos_coin::mint(aptos_framework, admin_addr, INITIAL_APT_BALANCE);
        
        // Setup all users
        let i = 0;
        while (i < vector::length(&users)) {
            let user = vector::borrow(&users, i);
            let user_addr = signer::address_of(*user);
            account::create_account_for_test(user_addr);
            coin::register<aptos_coin::AptosCoin>(*user);
            aptos_coin::mint(aptos_framework, user_addr, INITIAL_APT_BALANCE);
            i = i + 1;
        };
        
        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, alice = @0x2, bob = @0x3, charlie = @0x4)]
    fun test_full_token_lifecycle(
        aptos_framework: &signer,
        admin: &signer,
        alice: &signer,
        bob: &signer,
        charlie: &signer
    ) {
        let users = vector[alice, bob, charlie];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);
        let charlie_addr = signer::address_of(charlie);
        
        // 1. Admin creates a token with initial buy
        token_factory::create_fa(
            admin,
            string::utf8(b"LifecycleToken"),
            string::utf8(b"LIFE"),
            string::utf8(b"https://lifecycle.icon"),
            string::utf8(b"https://lifecycle.project"),
            option::some(MEDIUM_BUY)
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // 2. Multiple users buy tokens at different times (bonding curve effect)
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY);
        let alice_tokens_1 = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        
        bonding_curve_pool::buy_tokens(bob, fa_address, SMALL_BUY);
        let bob_tokens = bonding_curve_pool::get_token_balance(bob_addr, fa_address);
        
        bonding_curve_pool::buy_tokens(charlie, fa_address, SMALL_BUY);
        let charlie_tokens = bonding_curve_pool::get_token_balance(charlie_addr, fa_address);
        
        // Due to bonding curve, later buyers should get fewer tokens for same APT
        assert!(alice_tokens_1 > bob_tokens, 1);
        assert!(bob_tokens > charlie_tokens, 2);
        
        // 3. Alice buys more tokens (should get fewer than her first purchase)
        bonding_curve_pool::buy_tokens(alice, fa_address, SMALL_BUY);
        let alice_tokens_2 = bonding_curve_pool::get_token_balance(alice_addr, fa_address);
        let alice_second_purchase = alice_tokens_2 - alice_tokens_1;
        
        assert!(alice_second_purchase < alice_tokens_1, 3);
        
        // 4. Bob sells half his tokens
        let bob_sell_amount = bob_tokens / 2;
        let bob_apt_before_sell = coin::balance<aptos_coin::AptosCoin>(bob_addr);
        bonding_curve_pool::sell_tokens(bob, fa_address, bob_sell_amount);
        let bob_apt_after_sell = coin::balance<aptos_coin::AptosCoin>(bob_addr);
        let bob_apt_received = bob_apt_after_sell - bob_apt_before_sell;
        
        assert!(bob_apt_received > 0, 4);
        assert!(bonding_curve_pool::get_token_balance(bob_addr, fa_address) == bob_tokens - bob_sell_amount, 5);
        
        // 5. Check pool state
        let apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        let pool_token_balance = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        
        assert!(apt_reserves > 0, 6);
        assert!(pool_token_balance > 0, 7);
        
        debug::print(&string::utf8(b"=== Full Token Lifecycle Test ==="));
        debug::print(&string::utf8(b"Alice tokens (1st buy): "));
        debug::print(&alice_tokens_1);
        debug::print(&string::utf8(b"Alice tokens (2nd buy): "));
        debug::print(&alice_second_purchase);
        debug::print(&string::utf8(b"Bob tokens: "));
        debug::print(&bob_tokens);
        debug::print(&string::utf8(b"Charlie tokens: "));
        debug::print(&charlie_tokens);
        debug::print(&string::utf8(b"Bob APT received from sell: "));
        debug::print(&bob_apt_received);
        debug::print(&string::utf8(b"Pool APT reserves: "));
        debug::print(&apt_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, whale = @0x2)]
    fun test_graduation_scenario(
        aptos_framework: &signer,
        admin: &signer,
        whale: &signer
    ) {
        let users = vector[whale];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let whale_addr = signer::address_of(whale);
        
        // Give whale enough APT for graduation
        aptos_coin::mint(aptos_framework, whale_addr, 25000_00000000); // 25000 APT
        
        // Create token
        token_factory::create_fa(
            admin,
            string::utf8(b"GraduationToken"),
            string::utf8(b"GRAD"),
            string::utf8(b"https://grad.icon"),
            string::utf8(b"https://grad.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Check initial pool state
        let initial_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        let initial_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        assert!(initial_pool_tokens == 1_000_000_000_00000000, 1); // 1 billion tokens
        assert!(initial_reserves == 0, 2);
        
        // Whale makes large purchase to trigger graduation
        bonding_curve_pool::buy_tokens(whale, fa_address, GRADUATION_BUY);
        
        let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        let final_pool_tokens = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        let whale_tokens = bonding_curve_pool::get_token_balance(whale_addr, fa_address);
        
        // Pool should have graduated (reserves >= 21500 APT)
        assert!(final_reserves >= 21500_00000000, 3);
        
        // Remaining tokens should have been burned during graduation
        assert!(final_pool_tokens < initial_pool_tokens, 4);
        
        // Whale should have received tokens
        assert!(whale_tokens > 0, 5);
        
        debug::print(&string::utf8(b"=== Graduation Scenario Test ==="));
        debug::print(&string::utf8(b"Initial pool tokens: "));
        debug::print(&initial_pool_tokens);
        debug::print(&string::utf8(b"Final pool tokens: "));
        debug::print(&final_pool_tokens);
        debug::print(&string::utf8(b"Tokens burned: "));
        debug::print(&(initial_pool_tokens - final_pool_tokens));
        debug::print(&string::utf8(b"Final reserves: "));
        debug::print(&final_reserves);
        debug::print(&string::utf8(b"Whale tokens: "));
        debug::print(&whale_tokens);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, trader1 = @0x2, trader2 = @0x3)]
    fun test_trading_competition(
        aptos_framework: &signer,
        admin: &signer,
        trader1: &signer,
        trader2: &signer
    ) {
        let users = vector[trader1, trader2];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let trader1_addr = signer::address_of(trader1);
        let trader2_addr = signer::address_of(trader2);
        
        // Create token
        token_factory::create_fa(
            admin,
            string::utf8(b"TradingToken"),
            string::utf8(b"TRADE"),
            string::utf8(b"https://trade.icon"),
            string::utf8(b"https://trade.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Simulate trading competition
        let round = 0;
        while (round < 5) {
            // Trader1 buys
            bonding_curve_pool::buy_tokens(trader1, fa_address, SMALL_BUY);
            
            // Trader2 buys more
            bonding_curve_pool::buy_tokens(trader2, fa_address, SMALL_BUY * 2);
            
            // Trader1 sells some
            let trader1_balance = bonding_curve_pool::get_token_balance(trader1_addr, fa_address);
            if (trader1_balance > 0) {
                bonding_curve_pool::sell_tokens(trader1, fa_address, trader1_balance / 3);
            };
            
            round = round + 1;
        };
        
        let final_trader1_tokens = bonding_curve_pool::get_token_balance(trader1_addr, fa_address);
        let final_trader2_tokens = bonding_curve_pool::get_token_balance(trader2_addr, fa_address);
        let final_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        
        // Trader2 should have more tokens (bought more each round)
        assert!(final_trader2_tokens > final_trader1_tokens, 1);
        
        // Pool should have accumulated reserves
        assert!(final_reserves > 0, 2);
        
        debug::print(&string::utf8(b"=== Trading Competition Test ==="));
        debug::print(&string::utf8(b"Trader1 final tokens: "));
        debug::print(&final_trader1_tokens);
        debug::print(&string::utf8(b"Trader2 final tokens: "));
        debug::print(&final_trader2_tokens);
        debug::print(&string::utf8(b"Final pool reserves: "));
        debug::print(&final_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, creator = @0x2, user1 = @0x3, user2 = @0x4)]
    fun test_multiple_tokens_interaction(
        aptos_framework: &signer,
        admin: &signer,
        creator: &signer,
        user1: &signer,
        user2: &signer
    ) {
        let users = vector[creator, user1, user2];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let creator_addr = signer::address_of(creator);
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        
        // Create multiple tokens
        token_factory::create_fa(
            creator,
            string::utf8(b"TokenA"),
            string::utf8(b"TKA"),
            string::utf8(b"https://tokena.icon"),
            string::utf8(b"https://tokena.project"),
            option::some(MEDIUM_BUY)
        );
        
        token_factory::create_fa(
            admin,
            string::utf8(b"TokenB"),
            string::utf8(b"TKB"),
            string::utf8(b"https://tokenb.icon"),
            string::utf8(b"https://tokenb.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let token_a_obj = registry[vector::length(&registry) - 2];
        let token_b_obj = registry[vector::length(&registry) - 1];
        let token_a_addr = token_factory::get_fa_object_address(token_a_obj);
        let token_b_addr = token_factory::get_fa_object_address(token_b_obj);
        
        // Users trade different tokens
        bonding_curve_pool::buy_tokens(user1, token_a_addr, SMALL_BUY);
        bonding_curve_pool::buy_tokens(user1, token_b_addr, SMALL_BUY);
        
        bonding_curve_pool::buy_tokens(user2, token_a_addr, MEDIUM_BUY);
        bonding_curve_pool::buy_tokens(user2, token_b_addr, SMALL_BUY);
        
        // Check balances
        let user1_token_a = bonding_curve_pool::get_token_balance(user1_addr, token_a_addr);
        let user1_token_b = bonding_curve_pool::get_token_balance(user1_addr, token_b_addr);
        let user2_token_a = bonding_curve_pool::get_token_balance(user2_addr, token_a_addr);
        let user2_token_b = bonding_curve_pool::get_token_balance(user2_addr, token_b_addr);
        let creator_token_a = bonding_curve_pool::get_token_balance(creator_addr, token_a_addr);
        
        // Verify independent token economics
        assert!(user1_token_a > 0, 1);
        assert!(user1_token_b > 0, 2);
        assert!(user2_token_a > 0, 3);
        assert!(user2_token_b > 0, 4);
        assert!(creator_token_a > 0, 5); // Creator bought during creation
        
        // User2 bought more Token A, but due to bonding curve should have fewer tokens per APT
        assert!(user1_token_a > user2_token_a / 10, 6); // Rough comparison accounting for different amounts
        
        let reserves_a = bonding_curve_pool::get_apt_reserves(token_a_addr);
        let reserves_b = bonding_curve_pool::get_apt_reserves(token_b_addr);
        
        // Token A should have more reserves (creator buy + user purchases)
        assert!(reserves_a > reserves_b, 7);
        
        debug::print(&string::utf8(b"=== Multiple Tokens Interaction Test ==="));
        debug::print(&string::utf8(b"User1 Token A: "));
        debug::print(&user1_token_a);
        debug::print(&string::utf8(b"User1 Token B: "));
        debug::print(&user1_token_b);
        debug::print(&string::utf8(b"User2 Token A: "));
        debug::print(&user2_token_a);
        debug::print(&string::utf8(b"User2 Token B: "));
        debug::print(&user2_token_b);
        debug::print(&string::utf8(b"Creator Token A: "));
        debug::print(&creator_token_a);
        debug::print(&string::utf8(b"Token A reserves: "));
        debug::print(&reserves_a);
        debug::print(&string::utf8(b"Token B reserves: "));
        debug::print(&reserves_b);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_fee_distribution_across_operations(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        let users = vector[user];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let user_addr = signer::address_of(user);
        
        // Create token
        token_factory::create_fa(
            admin,
            string::utf8(b"FeeToken"),
            string::utf8(b"FEE"),
            string::utf8(b"https://fee.icon"),
            string::utf8(b"https://fee.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        let initial_treasury_balance = coin::balance<aptos_coin::AptosCoin>(@BullPump);
        let total_purchases = 0u64;
        
        // Multiple purchases to accumulate fees
        let purchase_amounts = vector[SMALL_BUY, MEDIUM_BUY, SMALL_BUY * 2, MEDIUM_BUY / 2];
        let i = 0;
        
        while (i < vector::length(&purchase_amounts)) {
            let amount = *vector::borrow(&purchase_amounts, i);
            bonding_curve_pool::buy_tokens(user, fa_address, amount);
            total_purchases = total_purchases + amount;
            i = i + 1;
        };
        
        let final_treasury_balance = coin::balance<aptos_coin::AptosCoin>(@BullPump);
        let total_fees_collected = final_treasury_balance - initial_treasury_balance;
        
        // Calculate expected fees (0.1% of total purchases)
        let expected_total_fees = total_purchases * 100 / 10000;
        
        assert!(total_fees_collected == expected_total_fees, 1);
        
        // User should have received tokens
        let user_tokens = bonding_curve_pool::get_token_balance(user_addr, fa_address);
        assert!(user_tokens > 0, 2);
        
        // Pool should have reserves (total purchases minus fees)
        let pool_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        assert!(pool_reserves == total_purchases - expected_total_fees, 3);
        
        debug::print(&string::utf8(b"=== Fee Distribution Test ==="));
        debug::print(&string::utf8(b"Total purchases: "));
        debug::print(&total_purchases);
        debug::print(&string::utf8(b"Expected fees: "));
        debug::print(&expected_total_fees);
        debug::print(&string::utf8(b"Actual fees collected: "));
        debug::print(&total_fees_collected);
        debug::print(&string::utf8(b"Pool reserves: "));
        debug::print(&pool_reserves);
        debug::print(&string::utf8(b"User tokens: "));
        debug::print(&user_tokens);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, early_user = @0x2, late_user = @0x3)]
    fun test_early_vs_late_adopter_advantage(
        aptos_framework: &signer,
        admin: &signer,
        early_user: &signer,
        late_user: &signer
    ) {
        let users = vector[early_user, late_user];
        setup_multi_user_env(aptos_framework, admin, users);
        
        let early_addr = signer::address_of(early_user);
        let late_addr = signer::address_of(late_user);
        
        // Create token
        token_factory::create_fa(
            admin,
            string::utf8(b"AdopterToken"),
            string::utf8(b"ADOPT"),
            string::utf8(b"https://adopt.icon"),
            string::utf8(b"https://adopt.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Early user buys first
        bonding_curve_pool::buy_tokens(early_user, fa_address, MEDIUM_BUY);
        let early_tokens = bonding_curve_pool::get_token_balance(early_addr, fa_address);
        
        // Simulate market activity (price goes up)
        let i = 0;
        while (i < 10) {
            bonding_curve_pool::buy_tokens(admin, fa_address, SMALL_BUY);
            i = i + 1;
        };
        
        // Late user buys same amount
        bonding_curve_pool::buy_tokens(late_user, fa_address, MEDIUM_BUY);
        let late_tokens = bonding_curve_pool::get_token_balance(late_addr, fa_address);
        
        // Early user should have gotten significantly more tokens for same APT
        assert!(early_tokens > late_tokens * 2, 1); // At least 2x advantage
        
        // Test selling advantage
        let early_apt_before_sell = coin::balance<aptos_coin::AptosCoin>(early_addr);
        let late_apt_before_sell = coin::balance<aptos_coin::AptosCoin>(late_addr);
        
        // Both sell same number of tokens
        let tokens_to_sell = late_tokens; // Use late_tokens as base (smaller amount)
        bonding_curve_pool::sell_tokens(early_user, fa_address, tokens_to_sell);
        bonding_curve_pool::sell_tokens(late_user, fa_address, tokens_to_sell);
        
        let early_apt_after_sell = coin::balance<aptos_coin::AptosCoin>(early_addr);
        let late_apt_after_sell = coin::balance<aptos_coin::AptosCoin>(late_addr);
        
        let early_apt_received = early_apt_after_sell - early_apt_before_sell;
        let late_apt_received = late_apt_after_sell - late_apt_before_sell;
        
        // Early user should receive more APT for same number of tokens (still has advantage)
        assert!(early_apt_received >= late_apt_received, 2);
        
        debug::print(&string::utf8(b"=== Early vs Late Adopter Test ==="));
        debug::print(&string::utf8(b"Early user tokens (10 APT): "));
        debug::print(&early_tokens);
        debug::print(&string::utf8(b"Late user tokens (10 APT): "));
        debug::print(&late_tokens);
        debug::print(&string::utf8(b"Early advantage ratio: "));
        debug::print(&(early_tokens / late_tokens));
        debug::print(&string::utf8(b"Early APT from sell: "));
        debug::print(&early_apt_received);
        debug::print(&string::utf8(b"Late APT from sell: "));
        debug::print(&late_apt_received);
    }
}
