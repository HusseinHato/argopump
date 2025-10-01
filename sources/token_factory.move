module ArgoPump::token_factory {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;

    #[test_only]
    use std::string;
    // use std::debug;

    use aptos_framework::aptos_account;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object, ObjectCore};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::account::{Self, SignerCapability};

    /// Only admin can update creator
    const EONLY_ADMIN_CAN_UPDATE_CREATOR: u64 = 1;
    /// Only admin can set pending admin
    const EONLY_ADMIN_CAN_SET_PENDING_ADMIN: u64 = 2;
    /// Sender is not pending admin
    const ENOT_PENDING_ADMIN: u64 = 3;
    /// Only admin can update mint fee collector
    const EONLY_ADMIN_CAN_UPDATE_MINT_FEE_COLLECTOR: u64 = 4;
    /// No mint limit
    const ENO_MINT_LIMIT: u64 = 5;
    /// Mint limit reached
    const EMINT_LIMIT_REACHED: u64 = 6;
    /// Not Enough Balance
    const ENOT_ENOUGH_BALANCE: u64 = 7;
    /// Cannot Be Zero
    const ECANNOT_BE_ZERO: u64 = 8;


    /// Default to mint 0 amount to creator when creating FA
    const DEFAULT_PRE_MINT_AMOUNT: u64 = 0;
    /// Default mint fee per smallest unit of FA denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
    const DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA: u64 = 0;
    /// Address of Bonding Curve contract
    const BONDING_CURVE_POOL_ADDRESS: address = @ArgoPump;
    /// Initial Supply of the FA created
    const INITIAL_BONDING_CURVE_SUPPLY: u128 = 800_000_000_00000000; // 800 million tokens with 8 decimal places
    /// Default number of decimal places for the FA created
    const DEFAULT_DECIMALS: u8 = 8;
    /// Reserved FA for liquidity pool
    const RESERVED_FA_FOR_LIQUDITY_POOL: u128 = 200_000_000_00000000; // 200 million tokens with 8 decimal places

    #[event]
    struct CreateFAEvent has store, drop {
        creator_addr: address,
        fa_obj: Object<Metadata>,
        max_supply: u128,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        mint_fee_per_smallest_unit_of_fa: u64,
    }

    #[event]
    struct MintFAEvent has store, drop {
        fa_obj: Object<Metadata>,
        amount: u64,
        recipient_addr: address,
        total_mint_fee: u64
    }

    #[event]
    struct BurnFAEvent has store, drop {
        fa_obj: Object<Metadata>,
        amount: u64,
        burner_addr: address
    }

    /// Unique per FA
    struct FAController has key {
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
        transfer_ref: fungible_asset::TransferRef
    }

    /// Unique per FA
    struct FAConfig has key {
        // Mint fee per FA denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
        mint_fee_per_smallest_unit_of_fa: u64,
    }

    /// Global PerContract
    struct Registry has key {
        fa_objects: vector<Object<Metadata>>
    }

    /// Global per contract
    struct Config has key {
        // admin can set pending admin, accept admin, update mint fee collector
        admin_addr: address,
        pending_admin_addr: Option<address>,
        mint_fee_collector_addr: address
    }

    /// Resource to store the FA creator resource account address
    struct FACreatorManager has key {
        resource_account: address,
    }

    /// Resource to store the signer capability at resource account
    struct ResourceAccountCap has key {
        signer_cap: SignerCapability,
    }

    /// If you deploy the module under an object, sender is the object's signer
    /// If you deploy the moduelr under your own account, sender is your account's signer
    fun init_module(sender: &signer) {
        move_to(sender, Registry {fa_objects: vector::empty()});
        move_to(
            sender,
            Config {
                admin_addr: signer::address_of(sender),
                pending_admin_addr: option::none(),
                mint_fee_collector_addr: signer::address_of(sender)
            }
        );
        
        // Initialize resource account for FA creation
        initialize_fa_creator(sender);
    }

    /// Initialize the FA creator resource account
    /// This creates a separate resource account to manage FA object creation
    fun initialize_fa_creator(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        if (!exists<FACreatorManager>(sender_addr)) {
            // Create a resource account for FA creation
            let (resource_signer, signer_cap) = account::create_resource_account(sender, b"fa_creator");
            let resource_addr = signer::address_of(&resource_signer);
            
            // Store capability at resource account
            move_to(&resource_signer, ResourceAccountCap { signer_cap });
            
            // Store resource account address at ArgoPump
            move_to(sender, FACreatorManager { resource_account: resource_addr });
        }
    }

    // ================================= Entry Functions ================================= //

    /// Set pending admin of the contract, then pending admin can call accept_admin to becom admin
    public entry fun set_pending_admin(sender: &signer, new_admin: address) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@ArgoPump);
        assert!(is_admin(config, sender_addr), EONLY_ADMIN_CAN_SET_PENDING_ADMIN);
        config.pending_admin_addr = option::some(new_admin);
    }

    public entry fun accept_admin(sender: &signer) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@ArgoPump);
        assert!(
            config.pending_admin_addr == option::some(sender_addr), ENOT_PENDING_ADMIN
        );
        config.admin_addr = sender_addr;
        config.pending_admin_addr = option::none();
    }

    /// Update mint fee collector address
    public entry fun update_mint_fee_collector(sender: &signer, new_mint_fee_collector: address) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@ArgoPump);
        assert!(
            is_admin(config, sender_addr), EONLY_ADMIN_CAN_UPDATE_MINT_FEE_COLLECTOR
        );
        config.mint_fee_collector_addr = new_mint_fee_collector;
    }

    /// Create a fungible asset, only admin or creator can create FA
    public entry fun create_fa(
        sender: &signer,
        // max_supply: Option<u128>,
        name: String,
        symbol: String,
        // Number of decimal places, i.e APT has 8 decimal places, so decimals = 8, 1 APT = 1e-8 oapt
        // decimals: u8,
        icon_uri: String,
        project_uri: String,
        amount_creator_buy: Option<u64>
    ) acquires Registry, FACreatorManager, ResourceAccountCap {
        let sender_addr = signer::address_of(sender);

        // Get the resource account signer to create FA objects
        let manager = borrow_global<FACreatorManager>(@ArgoPump);
        let resource_cap = borrow_global<ResourceAccountCap>(manager.resource_account);
        let resource_signer = account::create_signer_with_capability(&resource_cap.signer_cap);

        // Create FA object under resource account instead of @ArgoPump
        let fa_obj_constructor_ref = &object::create_sticky_object(signer::address_of(&resource_signer));
        let fa_obj_signer = &object::generate_signer(fa_obj_constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            option::some(INITIAL_BONDING_CURVE_SUPPLY + RESERVED_FA_FOR_LIQUDITY_POOL),
            name,
            symbol,
            DEFAULT_DECIMALS,
            icon_uri,
            project_uri
        );

        let fa_obj = object::object_from_constructor_ref(fa_obj_constructor_ref);
        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let mint_ref_copy = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let burn_ref_for_bonding_curve = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);
        let transfer_ref_for_bonding_curve = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);

        ArgoPump::bonding_curve_pool::initialize_pool(
            sender,
            fa_obj,
            transfer_ref_for_bonding_curve,
            burn_ref_for_bonding_curve
        );

        move_to(
            fa_obj_signer,
            FAController { mint_ref, burn_ref, transfer_ref }
        );

        let minted_tokens = fungible_asset::mint(&mint_ref_copy, (INITIAL_BONDING_CURVE_SUPPLY + RESERVED_FA_FOR_LIQUDITY_POOL) as u64);

        let pooL_store = primary_fungible_store::ensure_primary_store_exists(
            BONDING_CURVE_POOL_ADDRESS,
            fa_obj
        );

        fungible_asset::deposit(pooL_store, minted_tokens);

        move_to(
            fa_obj_signer,
            FAConfig {
                mint_fee_per_smallest_unit_of_fa: DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA
            }
        );

        let registry = borrow_global_mut<Registry>(@ArgoPump);
        registry.fa_objects.push_back(fa_obj);

        // if creator want to buy some tokens at the beginning
        if (amount_creator_buy.is_some()) {
            let amount = amount_creator_buy.extract();
            assert!(amount > 0, ECANNOT_BE_ZERO);
            ArgoPump::bonding_curve_pool::buy_tokens(
                sender,
                object::object_address(&fa_obj),
                amount
            );
        };

        event::emit(
            CreateFAEvent {
                creator_addr: sender_addr,
                fa_obj,
                max_supply: INITIAL_BONDING_CURVE_SUPPLY,
                name,
                symbol,
                decimals: DEFAULT_DECIMALS,
                icon_uri,
                project_uri,
                mint_fee_per_smallest_unit_of_fa: DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA
            }
        );

    }

    // Mint fungible asset, anyone with enough mint fee and has not reached mint limit can mint FA
    fun mint_fa(
        sender: &signer, fa_obj: Object<Metadata>, amount: u64
    ) acquires FAController, FAConfig, Config {
        let total_mint_fee = get_mint_fee(fa_obj, amount);
        pay_for_mint(sender, total_mint_fee);
        mint_fa_internal(sender, fa_obj, amount, total_mint_fee);
    }

    fun burn_fa(
        sender: &signer, fa_obj: Object<Metadata>, amount: u64
    ) acquires FAController {
        let sender_addr = signer::address_of(sender);
        check_user_fa_balance(fa_obj, sender_addr, amount);
        burn_fa_internal(fa_obj, sender, amount);
    }

    // ================================= View Functions ================================== //

    #[view]
    /// get all fungible assets created using this contract
    public fun get_registry(): vector<Object<Metadata>> acquires Registry {
        let registry = borrow_global<Registry>(@ArgoPump);
        registry.fa_objects
    }

    #[view]
    /// Get mint fee denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
    public fun get_mint_fee(
        fa_obj: Object<Metadata>,
        amount: u64
    ): u64 acquires FAConfig {
        let fa_config = borrow_global<FAConfig>(object::object_address(&fa_obj));
        amount * fa_config.mint_fee_per_smallest_unit_of_fa
    }


    #[view]
    /// Get contract admin
    public fun get_admin(): address acquires Config {
        let config = borrow_global<Config>(@ArgoPump);
        config.admin_addr
    }

    #[view]
    /// Get contract pending admin
    public fun get_pending_admin(): Option<address> acquires Config {
        let config = borrow_global<Config>(@ArgoPump);
        config.pending_admin_addr
    }

    #[view]
    /// Get mint fee collector address
    public fun get_mint_fee_collector(): address acquires Config {
        let config = borrow_global<Config>(@ArgoPump);
        config.mint_fee_collector_addr
    }

    #[view]
    /// Get FA Balance of an address
    fun get_balance_of_user(fa_obj: Object<Metadata>, addr: address): u64 {
        primary_fungible_store::balance(addr, fa_obj)
    }

    #[view]
    /// Get FA Balance of an address by FA object address
    public fun get_balance_of_user_by_fa_object_address(fa_obj_address: address, addr: address): u64 {
        let fa_obj = object::address_to_object<Metadata>(fa_obj_address);
        primary_fungible_store::balance(addr, fa_obj)
    }

    #[view]
    // get fungible asset Metadata
    public fun get_fa_object_metadata(fa_obj_address: address): (String, String, String, String, u8, Option<u128>) {
        let fa_obj = object::address_to_object<Metadata>(fa_obj_address);
        let name = fungible_asset::name(fa_obj);
        let symbol = fungible_asset::symbol(fa_obj);
        let icon_uri = fungible_asset::icon_uri(fa_obj);
        let project_uri = fungible_asset::project_uri(fa_obj);
        let decimals = fungible_asset::decimals(fa_obj);
        let max_supply = fungible_asset::maximum(fa_obj);

        (name, symbol, icon_uri, project_uri, decimals, max_supply)
    }

    #[view]
    /// Get FA object address
    public fun get_fa_object_address(fa_obj: Object<Metadata>): address {
        object::object_address(&fa_obj)
    }

    // ================================= Helper Functions ================================== //

    /// Check if sender is admin or owner of the object when package is published to object
    fun is_admin(config: &Config, sender: address): bool {
        if (sender == config.admin_addr) { true }
        else {
            if (object::is_object(@ArgoPump)) {
                let obj = object::address_to_object<ObjectCore>(@ArgoPump);
                object::is_owner(obj, sender)
            } else { false }
        }
    }

    /// ACtual implementation of minting FA
    fun mint_fa_internal(
        sender: &signer,
        fa_obj: Object<Metadata>,
        amount: u64,
        total_mint_fee: u64
    ) acquires FAController {
        let sender_addr = signer::address_of(sender);
        let fa_obj_addr = object::object_address(&fa_obj);

        let fa_controller = borrow_global<FAController>(fa_obj_addr);
        primary_fungible_store::mint(&fa_controller.mint_ref, sender_addr, amount);

        event::emit(
            MintFAEvent { fa_obj, amount, recipient_addr: sender_addr, total_mint_fee }
        );
    } 

    /// Actual implementation of burning FA
    fun burn_fa_internal(
        fa_obj: Object<Metadata>,
        sender: &signer,
        amount: u64
    ) acquires FAController {
        let sender_addr = signer::address_of(sender);
        let fa_obj_addr = object::object_address(&fa_obj);

        let fa_controller = borrow_global<FAController>(fa_obj_addr);

        primary_fungible_store::burn(&fa_controller.burn_ref, sender_addr, amount);

        event::emit(
            BurnFAEvent { fa_obj, amount, burner_addr: sender_addr }
        );
    }

    /// Check if user has enough FA balance
    fun check_user_fa_balance(
        fa_obj: Object<Metadata>,
        sender: address,
        amount: u64
    ) {
        assert!(
            get_balance_of_user(fa_obj, sender) >= amount,
            ENOT_ENOUGH_BALANCE
        )
    }

    /// Pay for mint
    fun pay_for_mint(sender: &signer, total_mint_fee: u64) acquires Config {
        if (total_mint_fee > 0) {
            let config = borrow_global<Config>(@ArgoPump);
            aptos_account::transfer(
                sender, config.mint_fee_collector_addr, total_mint_fee
            )
        }
    }

    // ================================= Unit Tests ================================== //

    #[test(sender = @ArgoPump)]
    fun test_create_fa(
        // aptos_framework: &signer,
        sender: &signer
    ) acquires Registry, FACreatorManager, ResourceAccountCap {

        init_module(sender);

        // create first FA
        create_fa(
            sender,
            string::utf8(b"Test"),
            string::utf8(b"TST"),
            string::utf8(b"icon_url"),
            string::utf8(b"project_url"),
            option::none()
        );

        let registry = get_registry();
        let fa_1 = registry[registry.length() - 1];
        assert!(fungible_asset::supply(fa_1) == option::some(INITIAL_BONDING_CURVE_SUPPLY + RESERVED_FA_FOR_LIQUDITY_POOL), 1);

        let (name, symbol, icon_uri, project_uri, decimals, max_supply) = get_fa_object_metadata(
            get_fa_object_address(fa_1)
        );

        debug::print(&name);
        debug::print(&symbol);
        debug::print(&icon_uri);
        debug::print(&project_uri);
        debug::print(&decimals);
        debug::print(&max_supply);

    }

    #[test_only]
    use ArgoPump::bonding_curve_pool::{Self};
    #[test_only]
    use std::debug;

    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use aptos_framework::coin;

    #[test(aptos_framework = @0x1, sender = @ArgoPump, alice = @0x2)]
    fun test_happy_path(
        sender: &signer,
        aptos_framework: &signer,
        alice: &signer
    ) acquires Registry, FACreatorManager, ResourceAccountCap {

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);

        init_module(sender);

        let creator_addr = signer::address_of(sender);

        // Initialize token_factory module first

        create_fa(
            sender,
            string::utf8(b"Test2"),
            string::utf8(b"TST2"),
            string::utf8(b"icon_url"),
            string::utf8(b"project_url"),
            option::none()
        );

        let registry = get_registry();
        let fa_2 = registry[registry.length() - 1];
        let fa_2_address = get_fa_object_address(fa_2);

        let alice_addr = signer::address_of(alice);

        account::create_account_for_test(alice_addr);
        coin::register<aptos_coin::AptosCoin>(alice);

        aptos_coin::mint(aptos_framework, alice_addr, 10_00000000);
        // 10_00000000 oapt = 10 APT

        bonding_curve_pool::buy_tokens(
            alice,
            fa_2_address,
            1_00000000, // 1_00000000 oapt = 1 APT
        );

        debug::print(&string::utf8(b"alice TST2 balance: "));
        debug::print(&bonding_curve_pool::get_token_balance(alice_addr, fa_2_address));
        debug::print(&bonding_curve_pool::get_token_balance(creator_addr, fa_2_address));
        debug::print(&bonding_curve_pool::get_apt_reserves(fa_2_address));

        // Clean up
        bonding_curve_pool::sell_tokens(
            alice,
            fa_2_address,
            bonding_curve_pool::get_token_balance(alice_addr, fa_2_address)
        );

        debug::print(&string::utf8(b"alice TST2 balance after sell: "));
        debug::print(&bonding_curve_pool::get_token_balance(alice_addr, fa_2_address));
        debug::print(&bonding_curve_pool::get_token_balance(creator_addr, fa_2_address));
        debug::print(&bonding_curve_pool::get_apt_reserves(fa_2_address));

        create_fa(
            alice,
            string::utf8(b"Test3"),
            string::utf8(b"TST3"),
            string::utf8(b"icon_url"),
            string::utf8(b"project_url"),
            option::some(1_00000000) // 1_00000000 oapt = 1 APT
        );

        let registry = get_registry();
        let fa_3 = registry[registry.length() - 1];
        let fa_3_address = get_fa_object_address(fa_3);

        debug::print(&string::utf8(b"alice TST3 balance after create: "));
        debug::print(&get_balance_of_user_by_fa_object_address(fa_3_address, alice_addr));
        debug::print(&bonding_curve_pool::get_apt_reserves(fa_3_address));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

    }

    
}