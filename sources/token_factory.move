module BullPump::token_factory {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;

    #[test_only]
    use std::string;
    use std::debug;

    use aptos_std::table::{Self, Table};

    use aptos_framework::aptos_account;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::{Self, Object, ObjectCore};
    use aptos_framework::primary_fungible_store;

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


    /// Default to mint 0 amount to creator when creating FA
    const DEFAULT_PRE_MINT_AMOUNT: u64 = 0;
    /// Default mint fee per smallest unit of FA denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
    const DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA: u64 = 0;
    /// Address of Bonding Curve contract
    const BONDING_CURVE_POOL_ADDRESS: address = @BullPump;
    /// Initial Supply of the FA created
    const INITIAL_BONDING_CURVE_SUPPLY: u64 = 1_000_000_000_00000000; // 1 billion tokens with 8 decimal places

    #[event]
    struct CreateFAEvent has store, drop {
        creator_addr: address,
        fa_obj: Object<Metadata>,
        max_supply: Option<u128>,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        mint_fee_per_smallest_unit_of_fa: u64,
        pre_mint_amount: u64,
        mint_limit_per_addr: Option<u64>
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

    /// Capability to create fungible asset, only admin or owner of the object can create FA
    public struct FactoryCapability has store, drop {}

    /// Unique per FA
    struct MintLimit has store {
        limit: u64,
        mint_tracker: Table<address, u64>
    }

    /// Unique per FA
    struct FAConfig has key {
        // Mint fee per FA denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
        mint_fee_per_smallest_unit_of_fa: u64,
        mint_limit: Option<MintLimit>
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
    }

    // ================================= Entry Functions ================================= //

    /// Set pending admin of the contract, then pending admin can call accept_admin to becom admin
    public entry fun set_pending_admin(sender: &signer, new_admin: address) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@BullPump);
        assert!(is_admin(config, sender_addr), EONLY_ADMIN_CAN_SET_PENDING_ADMIN);
        config.pending_admin_addr = option::some(new_admin);
    }

    public entry fun accept_admin(sender: &signer) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@BullPump);
        assert!(
            config.pending_admin_addr == option::some(sender_addr), ENOT_PENDING_ADMIN
        );
        config.admin_addr = sender_addr;
        config.pending_admin_addr = option::none();
    }

    /// Update mint fee collector address
    public entry fun update_mint_fee_collector(sender: &signer, new_mint_fee_collector: address) acquires Config {
        let sender_addr = signer::address_of(sender);
        let config = borrow_global_mut<Config>(@BullPump);
        assert!(
            is_admin(config, sender_addr), EONLY_ADMIN_CAN_UPDATE_MINT_FEE_COLLECTOR
        );
        config.mint_fee_collector_addr = new_mint_fee_collector;
    }

    /// Create a fungible asset, only admin or creator can create FA
    public entry fun create_fa(
        sender: &signer,
        max_supply: Option<u128>,
        name: String,
        symbol: String,
        // Numver of decimal places, i.e APT has 8 decimal places, so decimals = 8, 1 APT = 1e-8 oapt
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        // Mint fee per smallest unit of FA denominated in oapt (smallest unit of APT, i.e. 1e-* APT)
        mint_fee_per_smallest_unit_of_fa: Option<u64>,
        // Amount in smallest unit of FA
        pre_mint_amount: Option<u64>,
        // Limit of minting per addres in smallest unit of FA
        mint_limit_per_addr: Option<u64>
    ) acquires Registry, FAController {
        let sender_addr = signer::address_of(sender);

        let fa_obj_constructor_ref = &object::create_sticky_object(@BullPump);
        let fa_obj_signer = &object::generate_signer(fa_obj_constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            max_supply,
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let fa_obj = object::object_from_constructor_ref(fa_obj_constructor_ref);
        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);

        move_to(
            fa_obj_signer,
            FAController { mint_ref, burn_ref, transfer_ref }
        );

        BullPump::bonding_curve_pool::initialize_pool(
            sender,
            fa_obj,
            transfer_ref,
            FactoryCapability {}
        );

        fungible_asset::mint(&mint_ref, INITIAL_BONDING_CURVE_SUPPLY);

        move_to(
            fa_obj_signer,
            FAConfig {
                mint_fee_per_smallest_unit_of_fa: *mint_fee_per_smallest_unit_of_fa.borrow_with_default(
                    &DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA
                ),
                mint_limit: if (mint_limit_per_addr.is_some()) {
                    option::some(
                        MintLimit {
                            limit: *mint_limit_per_addr.borrow(),
                            mint_tracker: table::new()
                        }
                    )
                } else { option::none() }
            }
        );

        let registry = borrow_global_mut<Registry>(@BullPump);
        registry.fa_objects.push_back(fa_obj);

        event::emit(
            CreateFAEvent {
                creator_addr: sender_addr,
                fa_obj,
                max_supply,
                name,
                symbol,
                decimals,
                icon_uri,
                project_uri,
                mint_fee_per_smallest_unit_of_fa: *mint_fee_per_smallest_unit_of_fa.borrow_with_default(
                    &DEFAULT_MINT_FEE_PER_SMALLEST_UNIT_OF_FA
                ),
                pre_mint_amount: *pre_mint_amount.borrow_with_default(
                    &DEFAULT_PRE_MINT_AMOUNT
                ),
                mint_limit_per_addr
            }
        );

        if (*pre_mint_amount.borrow_with_default(&DEFAULT_PRE_MINT_AMOUNT) > 0) {
            let amount = *pre_mint_amount.borrow();
            mint_fa_internal(sender, fa_obj, amount, 0);
        }
    }

    // Mint fungible asset, anyone with enough mint fee and has not reached mint limit can mint FA
    public entry fun mint_fa(
        sender: &signer, fa_obj: Object<Metadata>, amount: u64
    ) acquires FAController, FAConfig, Config {
        let sender_addr = signer::address_of(sender);
        check_mint_limit_and_update_mint_tracker(sender_addr, fa_obj, amount);
        let total_mint_fee = get_mint_fee(fa_obj, amount);
        pay_for_mint(sender, total_mint_fee);
        mint_fa_internal(sender, fa_obj, amount, total_mint_fee);
    }

    public entry fun burn_fa(
        sender: &signer, fa_obj: Object<Metadata>, amount: u64
    ) acquires FAController, FAConfig {
        let sender_addr = signer::address_of(sender);
        check_user_fa_balance(fa_obj, sender_addr, amount);
        burn_fa_internal(fa_obj, sender, amount);
        reduce_mint_tracker(fa_obj, sender_addr, amount);
    }

    // ================================= View Functions ================================== //

    #[view]
    /// get all fungible assets created using this contract
    public fun get_registry(): vector<Object<Metadata>> acquires Registry {
        let registry = borrow_global<Registry>(@BullPump);
        registry.fa_objects
    }

    #[view]
    /// Get mint limit per address
    public fun get_mint_limit(fa_obj: Object<Metadata>): Option<u64> acquires FAConfig {
        let fa_config = borrow_global<FAConfig>(object::object_address(&fa_obj));
        if (fa_config.mint_limit.is_some()) {
            option::some(fa_config.mint_limit.borrow().limit)
        } else { option::none() }
    }

    #[view]
    /// Get current minted amount by an address
    public fun get_current_minted_amount(
        fa_obj: Object<Metadata>, addr: address
    ): u64 acquires FAConfig {
        let fa_config = borrow_global<FAConfig>(object::object_address(&fa_obj));
        assert!(fa_config.mint_limit.is_some(), ENO_MINT_LIMIT);
        let mint_limit = fa_config.mint_limit.borrow();
        let mint_tracker = &mint_limit.mint_tracker;
        *mint_tracker.borrow_with_default(addr, &0)
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
        let config = borrow_global<Config>(@BullPump);
        config.admin_addr
    }

    #[view]
    /// Get contract pending admin
    public fun get_pending_admin(): Option<address> acquires Config {
        let config = borrow_global<Config>(@BullPump);
        config.pending_admin_addr
    }

    #[view]
    /// Get mint fee collector address
    public fun get_mint_fee_collector(): address acquires Config {
        let config = borrow_global<Config>(@BullPump);
        config.mint_fee_collector_addr
    }

    #[view]
    /// Get FA Balance of an address
    public fun get_balance_of_user(fa_obj: Object<Metadata>, addr: address): u64 {
        primary_fungible_store::balance(addr, fa_obj)
    }

    #[view]
    // get fungible asset Metadata
    public fun get_fa_object_metadata(fa_obj: Object<Metadata>): (String, String, u8, Option<u128>, u64) {
        let name = fungible_asset::name(fa_obj);
        let symbol = fungible_asset::symbol(fa_obj);
        let decimals = fungible_asset::decimals(fa_obj);
        let max_supply = fungible_asset::maximum(fa_obj);
        let circulating_supply = fungible_asset::balance(fa_obj);

        (name, symbol, decimals, max_supply, circulating_supply)
    }

    // ================================= Helper Functions ================================== //

    /// Check if sender is admin or owner of the object when package is published to object
    fun is_admin(config: &Config, sender: address): bool {
        if (sender == config.admin_addr) { true }
        else {
            if (object::is_object(@BullPump)) {
                let obj = object::address_to_object<ObjectCore>(@BullPump);
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

    /// Reduce mint tracker
    fun reduce_mint_tracker(
        fa_obj: Object<Metadata>,
        sender: address,
        amount: u64
    ) acquires FAConfig {
        let mint_limit = get_mint_limit(fa_obj);
        if (mint_limit.is_some()) {
            let old_amount = get_current_minted_amount(fa_obj, sender);
            let fa_config = borrow_global_mut<FAConfig>(object::object_address(&fa_obj));
            let mint_limit = fa_config.mint_limit.borrow_mut();
            let mint_tracker = &mut mint_limit.mint_tracker;
            mint_tracker.upsert(sender, old_amount - amount);
        };
    }

    /// Check mint limit and update mint tracker
    fun check_mint_limit_and_update_mint_tracker(
        sender: address, fa_obj: Object<Metadata>, amount: u64
    ) acquires FAConfig {
        let mint_limit = get_mint_limit(fa_obj);
        if (mint_limit.is_some()) {
            let old_amount = get_current_minted_amount(fa_obj, sender);
            assert!(
                old_amount + amount <= *mint_limit.borrow(),
                EMINT_LIMIT_REACHED
            );
            let  fa_config = borrow_global_mut<FAConfig>(object::object_address(&fa_obj));
            let mint_limit = fa_config.mint_limit.borrow_mut();
            mint_limit.mint_tracker.upsert(sender, old_amount + amount)
        }
    }

    /// Pay for mint
    fun pay_for_mint(sender: &signer, total_mint_fee: u64) acquires Config {
        if (total_mint_fee > 0) {
            let config = borrow_global<Config>(@BullPump);
            aptos_account::transfer(
                sender, config.mint_fee_collector_addr, total_mint_fee
            )
        }
    }

    // ================================= Unit Tests ================================== //

    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    use aptos_framework::account;

    #[test(aptos_framework = @0x1, sender = @BullPump)]
    fun test_happy_path(
        aptos_framework: &signer, sender: &signer
    ) acquires Registry, FAController, Config, FAConfig {
        // let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);

        let sender_addr = signer::address_of(sender);

        init_module(sender);

        // create first FA

        create_fa(
            sender,
            option::some(1000),
            string::utf8(b"Test"),
            string::utf8(b"TST"),
            2,
            string::utf8(b"icon_url"),
            string::utf8(b"project_url"),
            option::none(),
            option::none(),
            option::some(500)
        );

        let registry = get_registry();
        let fa_1 = registry[registry.length() - 1];
        assert!(fungible_asset::supply(fa_1) == option::some(0), 1);

        mint_fa(sender, fa_1, 50);
        let sender_balance = get_balance_of_user(fa_1, sender_addr);
        assert!(fungible_asset::supply(fa_1) == option::some(50), 2);
        assert!(sender_balance == 50, 3);

        create_fa(
            sender,
            option::some(1000),
            string::utf8(b"Test2"),
            string::utf8(b"TST2"),
            3,
            string::utf8(b"icon_url2"),
            string::utf8(b"project_url2"),
            option::none(),
            option::none(),
            option::some(500)
        );

        let registry = get_registry();
        let fa_2 = registry[registry.length() - 1];
        assert!(fungible_asset::supply(fa_2) == option::some(0), 4);

        mint_fa(sender, fa_2, 70);
        let sender_balance = get_balance_of_user(fa_2, sender_addr);
        assert!(fungible_asset::supply(fa_2) == option::some(70), 5);
        assert!(sender_balance == 70, 6);
    }
}