module BullPump::bonding_curve_pool {
    use std::signer;
    // use std::error;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, TransferRef, BurnRef};
    use aptos_std::table::{Self, Table};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::event;
    // use std::debug;

    // Friend module to allow access to initialize_pool function
    friend BullPump::token_factory;

    /// Token Factory Address
    const TOKEN_FACTORY_ADDRESS: address = @BullPump;

    /// Virtual APT reserves to stabilize the curve.
    const VIRTUAL_APT_RESERVES: u64 = 28_24_00000000;
    /// 28_24_00000000 octas = 28.24 APT

    /// Graduation threshold in APT (in octas, 1 APT = 10^8 octas).
    const GRADUATION_THRESHOLD: u64 = 21_500_00000000; // 21500 APT

    /// Fee percentage (in basis points, 1% = 100 basis points).
    const FEE_BASIS_POINTS: u64 = 100; // 0.1%

    /// Fee denominator for basis points calculation.
    const BASIS_POINTS_DENOMINATOR: u64 = 10_000;

    /// Address to collect fees.
    const TREASURY_ADDRESS: address = @BullPump;

    // --- Errors ---

    /// Error: Pool already exists. This error occurs when trying to initialize a pool that already exists for the given token.
    const EPOOL_ALREADY_EXISTS: u64 = 1;
    /// Error: pool not found
    const EPOOL_NOT_FOUND: u64 = 2;
    /// Error: pool is graduated
    const EPOOL_IS_GRADUATED: u64 = 3;
    /// Error: zero input amount
    const EZERO_INPUT_AMOUNT: u64 = 4;

    // --- Events ---

    #[event]
    struct TokenPurchaseEvent has copy, drop, store {
        buyer: address,
        fa_object: address,
        apt_in: u64,
        tokens_out: u64,
    }

    #[event]
    struct TokenSaleEvent has copy, drop, store {
        seller: address,
        fa_object: address,
        tokens_in: u64,
        apt_out: u64,
    }


    // --- Structs ---

    /// Store Pool data.
    struct Pool has store {
        sender: address,
        fa_object: Object<Metadata>,
        apt_reserves: Coin<AptosCoin>,
        is_graduated: bool,
    }

    /// Core resource to store all pools.
    struct AllPools has key {
        pools: Table<address, Pool>, // Key: FA object address, Value: Pool
    }

    struct FungibleAssetRefs has store {
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
    }

    /// Resource to store delegated TransferRefs for each FA object.
    struct DelegatedRefs has key {
        refs: Table<address, FungibleAssetRefs>, // Key: FA object address, Value: TransferRef
    }

    /// This function is called by the Token Factory to initialize a new bonding curve pool.
    public(friend) fun initialize_pool(
        sender: &signer,
        fa_obj: Object<Metadata>,
        transfer_ref: TransferRef,
        burn_ref: BurnRef
    ) acquires AllPools, DelegatedRefs {
        // Initialize resources if not exists
        if (!exists<AllPools>(@BullPump)) {
            move_to(sender, AllPools { pools: table::new() });
            move_to(sender, DelegatedRefs { refs: table::new() });
        };

        let fa_obj_addr = object::object_address(&fa_obj);
        let all_pools_ref = borrow_global_mut<AllPools>(@BullPump);
        assert!(!all_pools_ref.pools.contains(fa_obj_addr), EPOOL_ALREADY_EXISTS);

        // create new pool
        let new_pool = Pool {
            fa_object: fa_obj,
            apt_reserves: coin::zero<AptosCoin>(),
            sender: signer::address_of(sender),
            is_graduated: false,
        };

        all_pools_ref.pools.add(fa_obj_addr, new_pool);

        let fungible_asset_refs = FungibleAssetRefs {
            transfer_ref,
            burn_ref,
        };

        // Store the delegated TransferRef
        let all_refs_ref = borrow_global_mut<DelegatedRefs>(@BullPump);
        all_refs_ref.refs.add(fa_obj_addr, fungible_asset_refs);
    }

    /// Public function to buy tokens from the bonding curve pool.
    public entry fun buy_tokens(buyer: &signer, fa_obj_addr: address, amount: u64) acquires AllPools, DelegatedRefs {
        let all_pools_ref = borrow_global_mut<AllPools>(@BullPump);
        assert!(all_pools_ref.pools.contains(fa_obj_addr), EPOOL_NOT_FOUND);

        let pool = all_pools_ref.pools.borrow_mut(fa_obj_addr);
        assert!(!pool.is_graduated, EPOOL_IS_GRADUATED);
        assert!(amount > 0, EZERO_INPUT_AMOUNT);

        let total_apt_paid = coin::withdraw<AptosCoin>(buyer, amount);

        let fee_amount = ((amount as u128) * (FEE_BASIS_POINTS as u128) / (BASIS_POINTS_DENOMINATOR as u128)) as u64;

        // Split the total paid APT into the fee and the amount for the curve
        let fee_coin = coin::extract(&mut total_apt_paid, fee_amount);
        let apt_for_curve = total_apt_paid; // The remainder is for the curve

        // Send fee to fee collector
        coin::deposit(TREASURY_ADDRESS, fee_coin);

        // Withdraw APT from buyer
        let apt_in_for_curve = coin::value(&apt_for_curve);

        // Get the delegated TransferRef for the FA object.
        let all_refs_ref = borrow_global<DelegatedRefs>(@BullPump);
        let fa_refs = all_refs_ref.refs.borrow(fa_obj_addr);
        let burn_ref = &fa_refs.burn_ref;
        let transfer_ref = &fa_refs.transfer_ref;

        // Math for bonding curve
        let x = coin::value(&pool.apt_reserves) + VIRTUAL_APT_RESERVES;

        // Ensure pool's store exists and get the current balance
        let pool_store = primary_fungible_store::ensure_primary_store_exists(
            @BullPump,
            pool.fa_object
        );

        // Get token supply
        let y = fungible_asset::balance(pool_store);

        // Calculate tokens to send out using the formula:
        let tokens_out = (((y as u128) * (apt_in_for_curve as u128)) / ((x as u128) + (apt_in_for_curve as u128))) as u64;

        // Buyer's address
        let buyer_addr = signer::address_of(buyer);

        // Transfer tokens from pool to buyer
        let from_store = primary_fungible_store::ensure_primary_store_exists(@BullPump, pool.fa_object);

        let to_store = primary_fungible_store::ensure_primary_store_exists(buyer_addr, pool.fa_object);


        fungible_asset::transfer_with_ref(transfer_ref, from_store, to_store, tokens_out);

        // Renew pool's APT reserves
        coin::merge(&mut pool.apt_reserves, apt_for_curve);

        // Check for graduation
        if (coin::value(&pool.apt_reserves) >= GRADUATION_THRESHOLD) {
            pool.is_graduated = true;
            // TODO: Implement logic to burn remaining tokens and create a DEX pool.
            let pool_store = primary_fungible_store::ensure_primary_store_exists(@BullPump, pool.fa_object);
            let remaining_balance = fungible_asset::balance(pool_store);

            if (remaining_balance > 0) {

                // Withdraw all remaining tokens into a temporary object
                let remaining_tokens = fungible_asset::withdraw_with_ref(transfer_ref, pool_store, remaining_balance);

                // Get the BurnerRef for this specific FA (you would have stored this when you created it)
                // Burn them permanently!
                fungible_asset::burn(burn_ref, remaining_tokens);
            }
        };

        // Emit event
        event::emit<TokenPurchaseEvent>(
            TokenPurchaseEvent {
                buyer: buyer_addr,
                fa_object: fa_obj_addr,
                apt_in: apt_in_for_curve,
                tokens_out,
            }
        );
    }

    public entry fun sell_tokens(seller: &signer, fa_obj_addr: address, token_amount: u64) acquires AllPools, DelegatedRefs {
        let all_pools_ref = borrow_global_mut<AllPools>(@BullPump);
        assert!(all_pools_ref.pools.contains(fa_obj_addr), EPOOL_NOT_FOUND);

        let pool = all_pools_ref.pools.borrow_mut(fa_obj_addr);
        assert!(!pool.is_graduated, EPOOL_IS_GRADUATED);
        assert!(token_amount > 0, EZERO_INPUT_AMOUNT);

        // Get the delegated TransferRef and BurnRef for the FA object.
        let all_refs_ref = borrow_global_mut<DelegatedRefs>(@BullPump);
        let fa_refs = all_refs_ref.refs.borrow(fa_obj_addr);
        let transfer_ref = &fa_refs.transfer_ref;

        // Ensure seller's store exists
        let seller_addr = signer::address_of(seller);
        let seller_store = primary_fungible_store::ensure_primary_store_exists(seller_addr, pool.fa_object);

        // Withdraw tokens from seller
        let tokens_in = fungible_asset::withdraw_with_ref(transfer_ref, seller_store, token_amount);

        // Math for bonding curve
        let x = coin::value(&pool.apt_reserves) + VIRTUAL_APT_RESERVES;

        // Ensure pool's store exists and get the current balance
        let pool_store = primary_fungible_store::ensure_primary_store_exists(@BullPump, pool.fa_object);

        // Get token supply
        let y = fungible_asset::balance(pool_store);

        // Calculate APT to send out using the formula:
        let apt_out = (((x as u128) * (token_amount as u128)) / ((y as u128) + (token_amount as u128))) as u64;

        // Ensure the pool has enough APT reserves
        assert!(coin::value(&pool.apt_reserves) >= apt_out, EZERO_INPUT_AMOUNT);

        // Deposit tokens into pool's store
        fungible_asset::deposit(pool_store, tokens_in);

        // Withdraw APT from pool reserves to send to seller
        let apt_to_send = coin::extract(&mut pool.apt_reserves, apt_out);

        // Send APT to seller
        coin::deposit(seller_addr, apt_to_send);

        // Emit event
        event::emit<TokenSaleEvent>(
            TokenSaleEvent {    
                seller: seller_addr,
                fa_object: fa_obj_addr,
                tokens_in: token_amount,
                apt_out,
            }
        );
    }

    #[view]
    /// Get the token balance for a specific account
    public fun get_token_balance(
        account: address,
        fa_obj_addr: address
    ): u64 acquires AllPools {
        let all_pools = borrow_global<AllPools>(@BullPump);
        assert!(all_pools.pools.contains(fa_obj_addr), EPOOL_NOT_FOUND);

        let pool = all_pools.pools.borrow(fa_obj_addr);
        let store = primary_fungible_store::primary_store(account, pool.fa_object);
        
        fungible_asset::balance(store)
    }

    #[view]
    /// Get the APT reserves of a specific pool
    public fun get_apt_reserves(fa_obj_addr: address): u64 acquires AllPools {
        let all_pools = borrow_global<AllPools>(@BullPump);
        assert!(all_pools.pools.contains(fa_obj_addr), EPOOL_NOT_FOUND);
        let pool = all_pools.pools.borrow(fa_obj_addr);
        coin::value(&pool.apt_reserves)
    }

}