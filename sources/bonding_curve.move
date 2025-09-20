module BullPump::bonding_curve_pool {
    use std::signer;
    // use std::error;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Self, Metadata, TransferRef};
    use aptos_std::table::{Self, Table};
    use aptos_framework::primary_fungible_store;

    // Friend module to allow access to initialize_pool function
    friend BullPump::token_factory;

    // import capability from token_factory
    use BullPump::token_factory::FactoryCapability;

    /// Alamat pabrik token. Digunakan untuk pemeriksaan keamanan.
    const TOKEN_FACTORY_ADDRESS: address = @BullPump;

    /// Cadangan APT virtual untuk menyediakan likuiditas awal. 1,000,000 octas = 0.01 APT.
    const VIRTUAL_APT_RESERVES: u64 = 1_000_000;

    /// Ambang batas kelulusan (graduation threshold) dalam octas.
    const GRADUATION_THRESHOLD: u64 = 21_500_000_000_000; // 12500 APT

    // --- Errors ---

    /// Error: Pool already exists. This error occurs when trying to initialize a pool that already exists for the given token.
    const EPOOL_ALREADY_EXISTS: u64 = 1;
    /// Error: pool not found
    const EPOOL_NOT_FOUND: u64 = 2;
    /// Error: pool is graduated
    const EPOOL_IS_GRADUATED: u64 = 3;
    /// Error: zero input amount
    const EZERO_INPUT_AMOUNT: u64 = 4;

    // --- Structs ---

    /// Menyimpan state dari satu pool bonding curve.
    struct Pool has store {
        sender: address,
        fa_object: Object<Metadata>,
        apt_reserves: Coin<AptosCoin>,
        is_graduated: bool,
    }

    /// Resource utama yang menyimpan tabel semua pool. Disimpan di bawah akun kontrak.
    struct AllPools has key {
        pools: Table<address, Pool>, // Kunci: alamat objek FA, Nilai: struct Pool
    }

    /// Resource untuk menyimpan TransferRef yang didelegasikan.
    struct DelegatedRefs has key {
        refs: Table<address, TransferRef>, // Kunci: alamat objek FA, Nilai: TransferRef
    }

    /// Fungsi ini HANYA bisa dipanggil oleh token_factory kita.
    public(friend) fun initialize_pool(
        sender: &signer,
        fa_obj: Object<Metadata>,
        transfer_ref: TransferRef,
        _capability: FactoryCapability, // Bukti panggilan berasal dari pabrik
    ) {
        // Inisialisasi resource kontrak jika ini adalah pool pertama yang pernah ada.
        if (!exists<AllPools>(@BullPump)) {
            move_to(sender, AllPools { pools: table::new() });
            move_to(sender, DelegatedRefs { refs: table::new() });
        };

        let fa_obj_addr = object::object_address(&fa_obj);
        let all_pools_ref = borrow_global_mut<AllPools>(@BullPump);
        assert!(!all_pools_ref.pools.contains(fa_obj_addr), EPOOL_ALREADY_EXISTS);

        // Buat pool baru.
        let new_pool = Pool {
            fa_object: fa_obj,
            apt_reserves: coin::zero<AptosCoin>(),
            sender: signer::address_of(sender),
            is_graduated: false,
        };

        all_pools_ref.pools.add(fa_obj_addr, new_pool);

        // Simpan TransferRef yang didelegasikan.
        let all_refs_ref = borrow_global_mut<DelegatedRefs>(@BullPump);
        all_refs_ref.refs.add(fa_obj_addr, transfer_ref);
    }

    /// Fungsi publik bagi setiap pengguna untuk membeli token dengan APT.
    public entry fun buy_tokens(buyer: &signer, fa_obj_addr: address, apt_to_spend: Coin<AptosCoin>) {
        let all_pools_ref = borrow_global_mut<AllPools>(@BullPump);
        assert!(all_pools_ref.pools.contains(fa_obj_addr), EPOOL_NOT_FOUND);

        let pool = all_pools_ref.pools.borrow_mut(fa_obj_addr);
        assert!(!pool.is_graduated, EPOOL_IS_GRADUATED);
        assert!(coin::value(&apt_to_spend) > 0, EZERO_INPUT_AMOUNT);

        // Dapatkan TransferRef yang didelegasikan.
        let all_refs_ref = borrow_global<DelegatedRefs>(@BullPump);
        let transfer_ref = all_refs_ref.refs.borrow(fa_obj_addr);

        // --- Matematika Bonding Curve (Formula XYK Sederhana) ---
        let apt_in = coin::value(&apt_to_spend);
        let x = coin::value(&pool.apt_reserves) + VIRTUAL_APT_RESERVES;
        // Dapatkan suplai token saat ini langsung dari objek FA.
        let y = fungible_asset::balance(pool.fa_object);

        let tokens_out = (((y as u128) * (apt_in as u128)) / ((x as u128) + (apt_in as u128))) as u64;

        let buyer_addr = signer::address_of(buyer);
        let to_store = primary_fungible_store::ensure_primary_store_exists(buyer_addr, pool.fa_object);

        let from_store = primary_fungible_store::primary_store(@BullPump, pool.fa_object);


        fungible_asset::transfer_with_ref(transfer_ref, from_store, to_store, tokens_out);

        // Perbarui state pool.
        coin::merge(&mut pool.apt_reserves, apt_to_spend);

        // --- Periksa Kelulusan ---
        if (coin::value(&pool.apt_reserves) >= GRADUATION_THRESHOLD) {
            pool.is_graduated = true;
            // TODO: Implement logic to burn remaining tokens and create a DEX pool.
        }
    }

}