module ArgoPump::graduation_handler {
    use std::signer;
    use std::vector;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, TransferRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::event;
    use aptos_std::bcs_stream;
    use std::option;

    // Friend modules
    friend ArgoPump::bonding_curve_pool;

    /// Reserved FA for liquidity pool (200 million tokens with 8 decimals)
    const RESERVED_FA_FOR_LIQUIDITY_POOL: u128 = 200_000_000_00000000;
    
    /// Address of the ArgoPump contract
    const ARGOPUMP_ADDRESS: address = @ArgoPump;

    /// Error codes
    /// Pool creation failed
    const EPOOL_CREATION_FAILED: u64 = 1;
    /// Insufficient reserves
    const EINSUFFICIENT_RESERVES: u64 = 2;
    /// Resource account capability not found
    const ERESOURCE_ACCOUNT_NOT_FOUND: u64 = 3;

    /// Event emitted when a graduated pool is created
    #[event]
    struct GraduatedPoolCreatedEvent has drop, store {
        fa_object: address,
        pool_address: address,
        apt_amount: u64,
        fa_amount: u64,
        lp_shares: u64,
    }

    /// Resource to store the resource account address
    struct GraduationPoolManager has key {
        resource_account: address,
    }

    /// Resource to store the signer capability at resource account
    struct ResourceAccountCap has key {
        signer_cap: aptos_framework::account::SignerCapability,
    }

    /// Initialize the graduation handler with a resource account
    /// This should be called once during module initialization
    public entry fun initialize(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        if (sender_addr == ARGOPUMP_ADDRESS && !exists<GraduationPoolManager>(ARGOPUMP_ADDRESS)) {
            // Create a resource account for pool creation
            let (resource_signer, signer_cap) = aptos_framework::account::create_resource_account(sender, b"graduation_pools");
            let resource_addr = signer::address_of(&resource_signer);
            
            // Store capability at resource account
            move_to(&resource_signer, ResourceAccountCap { signer_cap });
            
            // Store resource account address at ArgoPump
            move_to(sender, GraduationPoolManager { resource_account: resource_addr });
        }
    }

    /// This function is called by the bonding curve when a token graduates.
    /// It creates a liquidity pool and adds the initial liquidity.
    public(friend) fun handle_graduation(
        fa_obj: Object<Metadata>,
        apt_reserves: Coin<AptosCoin>,
        transfer_ref: &TransferRef
    ) acquires GraduationPoolManager, ResourceAccountCap {
        let fa_obj_addr = object::object_address(&fa_obj);
        let apt_amount = coin::value(&apt_reserves);
        
        // Ensure we have sufficient reserves
        assert!(apt_amount > 0, EINSUFFICIENT_RESERVES);

        // Get the reserved FA tokens from the bonding curve pool
        let pool_store = primary_fungible_store::ensure_primary_store_exists(
            ARGOPUMP_ADDRESS,
            fa_obj
        );
        let fa_balance = fungible_asset::balance(pool_store);
        
        // The remaining balance should be the 200M reserved tokens
        assert!(fa_balance > 0, EINSUFFICIENT_RESERVES);
        let fa_amount = fa_balance;

        // Create a deterministic pool address using the FA object address
        let assets = vector::empty<address>();
        // For APT/FA pair, we'll use APT as token0 and FA as token1
        let apt_addr = @0x1; // AptosCoin type address
        assets.push_back(apt_addr);
        assets.push_back(fa_obj_addr);
        
        // Fee: 30 bps = 0.30%
        let fee_bps: u64 = 30;
        
        // Get the resource account signer to create the pool
        let manager = borrow_global<GraduationPoolManager>(ARGOPUMP_ADDRESS);
        let resource_cap = borrow_global<ResourceAccountCap>(manager.resource_account);
        let resource_signer = aptos_framework::account::create_signer_with_capability(&resource_cap.signer_cap);
        
        // Generate pool seed and create pool signer as a named object
        let pool_seed = ArgoPump::basic::pool_seed(assets, fee_bps);
        let pool_constructor_ref = &object::create_named_object(&resource_signer, pool_seed);
        let pool_signer = &object::generate_signer(pool_constructor_ref);
        let pool_address = signer::address_of(pool_signer);

        // Create the pool
        ArgoPump::basic::create_pool(
            pool_signer,
            assets,
            fee_bps,
            ARGOPUMP_ADDRESS
        );

        // Transfer APT to pool address for liquidity
        coin::deposit(pool_address, apt_reserves);

        // Transfer FA tokens to pool address for liquidity
        let pool_fa_store = primary_fungible_store::ensure_primary_store_exists(
            pool_address,
            fa_obj
        );
        
        // Withdraw FA from bonding curve pool and deposit to LP pool
        let fa_tokens = fungible_asset::withdraw_with_ref(
            transfer_ref,
            pool_store,
            fa_amount
        );
        fungible_asset::deposit(pool_fa_store, fa_tokens);

        // Now add liquidity to the pool
        // Prepare BCS stream with amounts [apt_amount, fa_amount]
        let stream_bytes = vector::empty<u8>();
        let apt_bytes = aptos_std::bcs::to_bytes(&apt_amount);
        let fa_bytes = aptos_std::bcs::to_bytes(&fa_amount);
        stream_bytes.append(apt_bytes);
        stream_bytes.append(fa_bytes);
        let mut_stream = bcs_stream::new(stream_bytes);

        // Add liquidity - this will create the first position
        let (added_amounts, position_opt) = ArgoPump::basic::add_liquidity(
            pool_signer,
            option::none(),
            &mut mut_stream,
            ARGOPUMP_ADDRESS
        );

        let lp_shares = if (position_opt.is_some()) {
            let _position_id = position_opt.destroy_some();
            // We could track the position ID if needed
            // For now, just acknowledge it was created
            added_amounts[0] + added_amounts[1] // Approximate LP value
        } else {
            0
        };

        // Emit event
        event::emit(GraduatedPoolCreatedEvent {
            fa_object: fa_obj_addr,
            pool_address,
            apt_amount,
            fa_amount,
            lp_shares,
        });
    }

    #[view]
    /// Get the expected pool address for a given FA object
    public fun get_pool_address(fa_obj_addr: address): address {
        let apt_addr = @0x1;
        let assets = vector::empty<address>();
        assets.push_back(apt_addr);
        assets.push_back(fa_obj_addr);
        let fee_bps: u64 = 30;
        let pool_seed = ArgoPump::basic::pool_seed(assets, fee_bps);
        
        // Calculate the named object address
        object::create_object_address(&@ArgoPump, pool_seed)
    }
}
