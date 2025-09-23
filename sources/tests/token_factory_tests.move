#[test_only]
module BullPump::token_factory_tests {
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
    const INITIAL_APT_BALANCE: u64 = 1000_00000000; // 1000 APT
    const CREATOR_BUY_AMOUNT: u64 = 5_00000000; // 5 APT

    // Helper function to setup test environment
    fun setup_test_env(
        aptos_framework: &signer,
        admin: &signer
    ) {
        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Initialize token factory
        token_factory::test_init_module(admin);
        
        // Setup admin account with APT
        let admin_addr = signer::address_of(admin);
        coin::register<aptos_coin::AptosCoin>(admin);
        aptos_coin::mint(aptos_framework, admin_addr, INITIAL_APT_BALANCE);
        
        // Clean up
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_create_fa_basic(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        let initial_registry_length = vector::length(&token_factory::get_registry());
        
        // Create a fungible asset
        token_factory::create_fa(
            admin,
            string::utf8(b"TestToken"),
            string::utf8(b"TEST"),
            string::utf8(b"https://test.icon"),
            string::utf8(b"https://test.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let final_registry_length = vector::length(&registry);
        
        // Verify registry updated
        assert!(final_registry_length == initial_registry_length + 1, 1);
        
        // Get the created FA
        let fa_obj = registry[final_registry_length - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Verify FA metadata
        let (name, symbol, icon_uri, project_uri, decimals, max_supply) = 
            token_factory::get_fa_object_metadata(fa_address);
        
        assert!(name == string::utf8(b"TestToken"), 2);
        assert!(symbol == string::utf8(b"TEST"), 3);
        assert!(icon_uri == string::utf8(b"https://test.icon"), 4);
        assert!(project_uri == string::utf8(b"https://test.project"), 5);
        assert!(decimals == 8, 6);
        assert!(option::is_some(&max_supply), 7);
        
        // Verify initial supply in bonding curve pool
        let pool_balance = bonding_curve_pool::get_token_balance(@BullPump, fa_address);
        assert!(pool_balance == 1_000_000_000_00000000, 8); // 1 billion tokens
        
        debug::print(&string::utf8(b"=== Create FA Basic Test ==="));
        debug::print(&string::utf8(b"FA Address: "));
        debug::print(&fa_address);
        debug::print(&string::utf8(b"Name: "));
        debug::print(&name);
        debug::print(&string::utf8(b"Symbol: "));
        debug::print(&symbol);
        debug::print(&string::utf8(b"Pool balance: "));
        debug::print(&pool_balance);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_create_fa_with_creator_buy(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        let admin_addr = signer::address_of(admin);
        
        let initial_apt_balance = coin::balance<aptos_coin::AptosCoin>(admin_addr);
        
        // Create FA with creator buy
        token_factory::create_fa(
            admin,
            string::utf8(b"CreatorToken"),
            string::utf8(b"CREATOR"),
            string::utf8(b"https://creator.icon"),
            string::utf8(b"https://creator.project"),
            option::some(CREATOR_BUY_AMOUNT)
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Verify creator received tokens
        let creator_token_balance = token_factory::get_balance_of_user_by_fa_object_address(fa_address, admin_addr);
        assert!(creator_token_balance > 0, 1);
        
        // Verify APT was spent
        let final_apt_balance = coin::balance<aptos_coin::AptosCoin>(admin_addr);
        assert!(final_apt_balance < initial_apt_balance, 2);
        
        // Verify pool has APT reserves
        let apt_reserves = bonding_curve_pool::get_apt_reserves(fa_address);
        assert!(apt_reserves > 0, 3);
        
        debug::print(&string::utf8(b"=== Create FA with Creator Buy Test ==="));
        debug::print(&string::utf8(b"Creator token balance: "));
        debug::print(&creator_token_balance);
        debug::print(&string::utf8(b"APT spent: "));
        debug::print(&(initial_apt_balance - final_apt_balance));
        debug::print(&string::utf8(b"Pool APT reserves: "));
        debug::print(&apt_reserves);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_multiple_fa_creation(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        let token_names = vector[
            string::utf8(b"Token1"),
            string::utf8(b"Token2"),
            string::utf8(b"Token3")
        ];
        let token_symbols = vector[
            string::utf8(b"TK1"),
            string::utf8(b"TK2"),
            string::utf8(b"TK3")
        ];
        
        let i = 0;
        while (i < vector::length(&token_names)) {
            let name = *vector::borrow(&token_names, i);
            let symbol = *vector::borrow(&token_symbols, i);
            
            token_factory::create_fa(
                admin,
                name,
                symbol,
                string::utf8(b"https://icon.uri"),
                string::utf8(b"https://project.uri"),
                option::none()
            );
            
            i = i + 1;
        };
        
        let registry = token_factory::get_registry();
        assert!(vector::length(&registry) == 3, 1);
        
        // Verify each token has correct metadata
        i = 0;
        while (i < vector::length(&registry)) {
            let fa_obj = *vector::borrow(&registry, i);
            let fa_address = token_factory::get_fa_object_address(fa_obj);
            let (name, symbol, _, _, _, _) = token_factory::get_fa_object_metadata(fa_address);
            
            let expected_name = *vector::borrow(&token_names, i);
            let expected_symbol = *vector::borrow(&token_symbols, i);
            
            assert!(name == expected_name, 2);
            assert!(symbol == expected_symbol, 3);
            
            debug::print(&string::utf8(b"Token created: "));
            debug::print(&name);
            debug::print(&string::utf8(b" ("));
            debug::print(&symbol);
            debug::print(&string::utf8(b")"));
            
            i = i + 1;
        };
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    fun test_admin_functions(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        let user_addr = signer::address_of(user);
        
        // Test initial admin
        let current_admin = token_factory::get_admin();
        assert!(current_admin == signer::address_of(admin), 1);
        
        // Test set pending admin
        token_factory::set_pending_admin(admin, user_addr);
        let pending_admin = token_factory::get_pending_admin();
        assert!(option::is_some(&pending_admin), 2);
        assert!(*option::borrow(&pending_admin) == user_addr, 3);
        
        // Test accept admin
        token_factory::accept_admin(user);
        let new_admin = token_factory::get_admin();
        assert!(new_admin == user_addr, 4);
        
        // Test update mint fee collector
        token_factory::update_mint_fee_collector(user, @0x999);
        let fee_collector = token_factory::get_mint_fee_collector();
        assert!(fee_collector == @0x999, 5);
        
        debug::print(&string::utf8(b"=== Admin Functions Test ==="));
        debug::print(&string::utf8(b"Original admin: "));
        debug::print(&current_admin);
        debug::print(&string::utf8(b"New admin: "));
        debug::print(&new_admin);
        debug::print(&string::utf8(b"Fee collector: "));
        debug::print(&fee_collector);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    #[expected_failure(abort_code = 2)] // EONLY_ADMIN_CAN_SET_PENDING_ADMIN
    fun test_non_admin_cannot_set_pending_admin(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        // Non-admin tries to set pending admin
        token_factory::set_pending_admin(user, @0x999);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, user = @0x2)]
    #[expected_failure(abort_code = 3)] // ENOT_PENDING_ADMIN
    fun test_non_pending_admin_cannot_accept(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        // User tries to accept admin without being set as pending
        token_factory::accept_admin(user);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    #[expected_failure(abort_code = 8)] // ECANNOT_BE_ZERO
    fun test_create_fa_with_zero_creator_buy_fails(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        token_factory::create_fa(
            admin,
            string::utf8(b"TestToken"),
            string::utf8(b"TEST"),
            string::utf8(b"https://test.icon"),
            string::utf8(b"https://test.project"),
            option::some(0) // Zero amount should fail
        );
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_get_balance_functions(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        let admin_addr = signer::address_of(admin);
        
        // Create FA with creator buy
        token_factory::create_fa(
            admin,
            string::utf8(b"BalanceTest"),
            string::utf8(b"BAL"),
            string::utf8(b"https://balance.icon"),
            string::utf8(b"https://balance.project"),
            option::some(CREATOR_BUY_AMOUNT)
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        // Test balance functions
        let balance1 = token_factory::get_balance_of_user_by_fa_object_address(fa_address, admin_addr);
        
        assert!(balance1 > 0, 1);
        
        debug::print(&string::utf8(b"=== Balance Functions Test ==="));
        debug::print(&string::utf8(b"Admin balance: "));
        debug::print(&balance1);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_fa_metadata_retrieval(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        let test_name = string::utf8(b"MetadataTest");
        let test_symbol = string::utf8(b"META");
        let test_icon = string::utf8(b"https://metadata.icon");
        let test_project = string::utf8(b"https://metadata.project");
        
        token_factory::create_fa(
            admin,
            test_name,
            test_symbol,
            test_icon,
            test_project,
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        let fa_address = token_factory::get_fa_object_address(fa_obj);
        
        let (name, symbol, icon_uri, project_uri, decimals, max_supply) = 
            token_factory::get_fa_object_metadata(fa_address);
        
        // Verify all metadata
        assert!(name == test_name, 1);
        assert!(symbol == test_symbol, 2);
        assert!(icon_uri == test_icon, 3);
        assert!(project_uri == test_project, 4);
        assert!(decimals == 8, 5);
        assert!(option::is_some(&max_supply), 6);
        assert!(*option::borrow(&max_supply) == 1_000_000_000_00000000, 7);
        
        debug::print(&string::utf8(b"=== Metadata Retrieval Test ==="));
        debug::print(&string::utf8(b"Name: "));
        debug::print(&name);
        debug::print(&string::utf8(b"Symbol: "));
        debug::print(&symbol);
        debug::print(&string::utf8(b"Decimals: "));
        debug::print(&decimals);
        debug::print(&string::utf8(b"Max Supply: "));
        debug::print(option::borrow(&max_supply));
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_mint_fee_calculation(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        token_factory::create_fa(
            admin,
            string::utf8(b"FeeTest"),
            string::utf8(b"FEE"),
            string::utf8(b"https://fee.icon"),
            string::utf8(b"https://fee.project"),
            option::none()
        );
        
        let registry = token_factory::get_registry();
        let fa_obj = registry[vector::length(&registry) - 1];
        
        // Test mint fee calculation (should be 0 by default)
        let fee_for_100 = token_factory::get_mint_fee(fa_obj, 100);
        let fee_for_1000 = token_factory::get_mint_fee(fa_obj, 1000);
        
        assert!(fee_for_100 == 0, 1); // Default fee is 0
        assert!(fee_for_1000 == 0, 2);
        
        debug::print(&string::utf8(b"=== Mint Fee Test ==="));
        debug::print(&string::utf8(b"Fee for 100 tokens: "));
        debug::print(&fee_for_100);
        debug::print(&string::utf8(b"Fee for 1000 tokens: "));
        debug::print(&fee_for_1000);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump, creator1 = @0x2, creator2 = @0x3)]
    fun test_multiple_creators(
        aptos_framework: &signer,
        admin: &signer,
        creator1: &signer,
        creator2: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        // Setup creators
        let creator1_addr = signer::address_of(creator1);
        let creator2_addr = signer::address_of(creator2);
        
        account::create_account_for_test(creator1_addr);
        account::create_account_for_test(creator2_addr);
        coin::register<aptos_coin::AptosCoin>(creator1);
        coin::register<aptos_coin::AptosCoin>(creator2);
        aptos_coin::mint(aptos_framework, creator1_addr, INITIAL_APT_BALANCE);
        aptos_coin::mint(aptos_framework, creator2_addr, INITIAL_APT_BALANCE);
        
        // Both creators create tokens
        token_factory::create_fa(
            creator1,
            string::utf8(b"Creator1Token"),
            string::utf8(b"C1T"),
            string::utf8(b"https://c1.icon"),
            string::utf8(b"https://c1.project"),
            option::some(CREATOR_BUY_AMOUNT)
        );
        
        token_factory::create_fa(
            creator2,
            string::utf8(b"Creator2Token"),
            string::utf8(b"C2T"),
            string::utf8(b"https://c2.icon"),
            string::utf8(b"https://c2.project"),
            option::some(CREATOR_BUY_AMOUNT)
        );
        
        let registry = token_factory::get_registry();
        assert!(vector::length(&registry) == 2, 1);
        
        // Verify each creator has their tokens
        let fa1_obj = registry[0];
        let fa2_obj = registry[1];
        let fa1_address = token_factory::get_fa_object_address(fa1_obj);
        let fa2_address = token_factory::get_fa_object_address(fa2_obj);
        
        let creator1_balance_fa1 = token_factory::get_balance_of_user_by_fa_object_address(fa1_address, creator1_addr);
        let creator1_balance_fa2 = token_factory::get_balance_of_user_by_fa_object_address(fa2_address, creator1_addr);
        let creator2_balance_fa1 = token_factory::get_balance_of_user_by_fa_object_address(fa1_address, creator2_addr);
        let creator2_balance_fa2 = token_factory::get_balance_of_user_by_fa_object_address(fa2_address, creator2_addr);
        
        assert!(creator1_balance_fa1 > 0, 2); // Creator1 has tokens from FA1
        assert!(creator1_balance_fa2 == 0, 3); // Creator1 has no tokens from FA2
        assert!(creator2_balance_fa1 == 0, 4); // Creator2 has no tokens from FA1
        assert!(creator2_balance_fa2 > 0, 5); // Creator2 has tokens from FA2
        
        debug::print(&string::utf8(b"=== Multiple Creators Test ==="));
        debug::print(&string::utf8(b"Creator1 FA1 balance: "));
        debug::print(&creator1_balance_fa1);
        debug::print(&string::utf8(b"Creator2 FA2 balance: "));
        debug::print(&creator2_balance_fa2);
    }

    #[test(aptos_framework = @0x1, admin = @BullPump)]
    fun test_registry_persistence(
        aptos_framework: &signer,
        admin: &signer
    ) {
        setup_test_env(aptos_framework, admin);
        
        // Create multiple tokens
        let num_tokens = 5;
        let i = 0;
        
        while (i < num_tokens) {
            let name = string::utf8(b"Token");
            string::append(&mut name, string::utf8(vector[48 + (i as u8)])); // Add number
            
            let symbol = string::utf8(b"TK");
            string::append(&mut symbol, string::utf8(vector[48 + (i as u8)])); // Add number
            
            token_factory::create_fa(
                admin,
                name,
                symbol,
                string::utf8(b"https://icon.uri"),
                string::utf8(b"https://project.uri"),
                option::none()
            );
            
            i = i + 1;
        };
        
        let registry = token_factory::get_registry();
        assert!(vector::length(&registry) == (num_tokens as u64), 1);
        
        // Verify all tokens are accessible
        i = 0;
        while (i < num_tokens) {
            let fa_obj = registry[i];
            let fa_address = token_factory::get_fa_object_address(fa_obj);
            let (name, symbol, _, _, _, _) = token_factory::get_fa_object_metadata(fa_address);
            
            debug::print(&string::utf8(b"Registry entry "));
            debug::print(&(i as u64));
            debug::print(&string::utf8(b": "));
            debug::print(&name);
            debug::print(&string::utf8(b" ("));
            debug::print(&symbol);
            debug::print(&string::utf8(b")"));
            
            i = i + 1;
        };
    }
}
