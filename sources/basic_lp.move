module ArgoPump::basic {
    use std::bcs::to_bytes;
    use std::option;
    use std::option::{Option};
    use std::vector;
    use aptos_std::bcs_stream::{BCSStream, deserialize_u64, deserialize_bool};
    use aptos_framework::ordered_map::{Self as ordered_map, OrderedMap};
    use std::signer;
    use aptos_framework::event;

    /// ===== Error codes =====
    const E_NOT_TWO_ASSETS: u64 = 1;
    const E_IDENTICAL_ASSETS: u64 = 2;
    const E_FEE_ZERO: u64 = 3;
    const E_FEE_TOO_HIGH: u64 = 4;
    const E_POOL_ALREADY_EXISTS: u64 = 5;

    const E_POSITION_NOT_FOUND: u64 = 10;
    const E_ZERO_AMOUNT: u64 = 11;
    const E_LP_SUPPLY_ZERO: u64 = 12;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 13;
    const E_SLIPPAGE: u64 = 14;

    /// ===== State =====

    struct PoolState has key {
        // meta
        state: u64,
        assets: vector<address>,          // [token0, token1]
        fee_bps: u64,                     // 1 bps = 0.01% (e.g. 30 = 0.30%)
        // reserves
        amounts: vector<u64>,             // [reserve0, reserve1]
        // LP shares
        lp_total_supply: u64,
        // toy positions
        positions: OrderedMap<u64, Position>,
        positions_count: u64
    }

    struct Position has copy, drop, store {
        value: u64 // LP shares owned by this position
    }

    // ===== Events =====

    #[event]
    struct Created has drop, store {
        pool: address,
        assets: vector<address>,
        fee_bps: u64
    }

    #[event]
    struct Added has drop, store {
        pool: address,
        position_id: u64,
        amount0: u64,
        amount1: u64,
        shares_minted: u64,
        lp_total_supply: u64
    }

    #[event]
    struct Removed has drop, store {
        pool: address,
        position_id: u64,
        amount0: u64,
        amount1: u64,
        shares_burned: u64,
        lp_total_supply: u64
    }

    #[event]
    struct Swapped has drop, store {
        pool: address,
        a2b: bool,
        amount_in: u64,
        amount_out: u64,
        fee_paid: u64,
        reserve0_after: u64,
        reserve1_after: u64
    }

    /// ===== Helpers =====

    /// Deterministic seed helper (useful if you want a predictable pool signer address upstream)
    public fun pool_seed(assets: vector<address>, fee: u64): vector<u8> {
        let seed = vector::empty<u8>();
        let a_bytes = to_bytes(&assets);
        let f_bytes = to_bytes(&fee);
        seed.append(a_bytes);
        seed.append(f_bytes);
        seed
    }

    inline fun min_u128(a: u128, b: u128): u128 {
        if (a < b) a else b
    }

    inline fun mul_div_u64(a: u64, b: u64, d: u64): u64 {
        // floor(a*b/d) in 128-bit space
        (((a as u128) * (b as u128)) / (d as u128)) as u64
    }

    /// Integer sqrt for u128 (Newton method), floor result.
    fun sqrt_u128(x: u128): u128 {
        if (x == 0) return 0;
        let z = x;
        let y = (x + 1) / 2;
        let zz = loop_newton(x, z, y);
        zz
    }

    fun loop_newton(x: u128, z: u128, y: u128): u128 {
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        };
        z
    }

    inline fun borrow_reserve(ps: &PoolState, i: u64): u64 {
        ps.amounts[i]
    }

    inline fun borrow_reserve_mut(ps: &mut PoolState, i: u64): &mut u64 {
        ps.amounts.borrow_mut(i)
    }

    /// ===== Core =====

    /// Create a pool at `pool_signer` with exactly 2 assets and fee in bps.
    public fun create_pool(
        pool_signer: &signer,
        assets: vector<address>,
        fee_bps: u64,
        _sender: address
    ) acquires PoolState {
        let pool_addr = signer::address_of(pool_signer);

        assert!(!exists<PoolState>(pool_addr), E_POOL_ALREADY_EXISTS);
        assert!(assets.length() == 2, E_NOT_TWO_ASSETS);

        let a0 = assets[0];
        let a1 = assets[1];
        assert!(a0 != a1, E_IDENTICAL_ASSETS);

        assert!(fee_bps > 0, E_FEE_ZERO);
        assert!(fee_bps < 10_000, E_FEE_TOO_HIGH);

        let amounts = vector::empty<u64>();
        amounts.push_back(0);
        amounts.push_back(0);

        move_to(
            pool_signer,
            PoolState {
                state: 0,
                assets,
                fee_bps,
                amounts,
                lp_total_supply: 0,
                positions: ordered_map::new(),
                positions_count: 0
            }
        );

        event::emit(Created {
            pool: pool_addr,
            assets: borrow_global<PoolState>(pool_addr).assets,
            fee_bps
        });
    }

    /// Add liquidity with potentially DIFFERENT amounts for token0 and token1.
    /// Stream layout: [u64 amount0_desired, u64 amount1_desired]
    public fun add_liquidity(
        pool_signer: &signer,
        position_idx: Option<u64>,
        stream: &mut BCSStream,
        _sender: address
    ): (vector<u64>, 0x1::option::Option<u64>) acquires PoolState {
        let pool_addr = signer::address_of(pool_signer);
        let ps = borrow_global_mut<PoolState>(pool_addr);
        let position_id: u64;

        let amount0_desired = deserialize_u64(stream);
        let amount1_desired = deserialize_u64(stream);
        assert!(amount0_desired > 0 && amount1_desired > 0, E_ZERO_AMOUNT);

        let r0 = ps.amounts[0];
        let r1 = ps.amounts[1];
        let lp_total_supply  = ps.lp_total_supply;

        let shares_minted: u64;
        let use0: u64;
        let use1: u64;

        if (lp_total_supply == 0) {
            // initial: shares = floor(sqrt(a0 * a1))
            let prod = ((amount0_desired as u128) * (amount1_desired as u128));
            let root = sqrt_u128(prod);
            shares_minted = root as u64;
            assert!(shares_minted > 0, E_ZERO_AMOUNT);

            use0 = amount0_desired;
            use1 = amount1_desired;
        } else {
            assert!(r0 > 0 && r1 > 0, E_INSUFFICIENT_LIQUIDITY);

            let mint0 = mul_div_u64(amount0_desired, lp_total_supply, r0);
            let mint1 = mul_div_u64(amount1_desired, lp_total_supply, r1);
            let mint  = min_u128(mint0 as u128, mint1 as u128);
            shares_minted = mint as u64;
            assert!(shares_minted > 0, E_ZERO_AMOUNT);

            // Actual used amounts proportional to current pool
            use0 = mul_div_u64(shares_minted, r0, lp_total_supply);
            use1 = mul_div_u64(shares_minted, r1, lp_total_supply);
        };

        // Update reserves
        *borrow_reserve_mut(ps, 0) = r0 + use0;
        *borrow_reserve_mut(ps, 1) = r1 + use1;
        ps.lp_total_supply = lp_total_supply + shares_minted;

        // Update/mint position
        let minted_pos_opt: Option<u64> = option::none();
        if (!position_idx.is_some()) {
            let id = ps.positions_count;
            ps.positions.add(id, Position { value: shares_minted });
            ps.positions_count = id + 1;
            minted_pos_opt = option::some(id);
            position_id = id;
        } else {
            let id = position_idx.destroy_some();
            assert!(ps.positions.contains(&id), E_POSITION_NOT_FOUND);
            let p = ps.positions.borrow_mut(&id);
            p.value += shares_minted;
            position_id = id;
        };

        event::emit(Added {
            pool: pool_addr,
            position_id,
            amount0: use0,
            amount1: use1,
            shares_minted,
            lp_total_supply: ps.lp_total_supply
        });

        let added = vector::empty<u64>();
        added.push_back(use0);
        added.push_back(use1);
        (added, minted_pos_opt)
    }

    /// Remove liquidity by burning LP shares from a position.
    /// Stream layout: [u64 shares_to_burn]
    public fun remove_liquidity(
        pool_signer: &signer,
        position_idx: u64,
        stream: &mut BCSStream,
        _sender: address
    ): (vector<u64>, 0x1::option::Option<u64>) acquires PoolState {
        let pool_addr = signer::address_of(pool_signer);
        let ps = borrow_global_mut<PoolState>(pool_addr);

        assert!(ps.positions.contains(&position_idx), E_POSITION_NOT_FOUND);
        let shares_to_burn = deserialize_u64(stream);
        assert!(shares_to_burn > 0, E_ZERO_AMOUNT);
        assert!(ps.lp_total_supply > 0, E_LP_SUPPLY_ZERO);

        let p = ps.positions.borrow_mut(&position_idx);
        assert!(p.value >= shares_to_burn, E_INSUFFICIENT_LIQUIDITY);

        let r0 = ps.amounts[0];
        let r1 = ps.amounts[1];
        let lp_total_supply  = ps.lp_total_supply;

        let out0 = mul_div_u64(shares_to_burn, r0, lp_total_supply);
        let out1 = mul_div_u64(shares_to_burn, r1, lp_total_supply);
        assert!(out0 <= r0 && out1 <= r1, E_INSUFFICIENT_LIQUIDITY);

        *borrow_reserve_mut(ps, 0) = r0 - out0;
        *borrow_reserve_mut(ps, 1) = r1 - out1;
        ps.lp_total_supply = lp_total_supply - shares_to_burn;

        p.value -= shares_to_burn;

        let removed_pos_opt: Option<u64> = option::none();
        if (p.value == 0) {
            ps.positions.remove(&position_idx);
            removed_pos_opt = option::some(position_idx);
        };

        event::emit(Removed {
            pool: pool_addr,
            position_id: position_idx,
            amount0: out0,
            amount1: out1,
            shares_burned: shares_to_burn,
            lp_total_supply: ps.lp_total_supply
        });

        let out = vector::empty<u64>();
        out.push_back(out0);
        out.push_back(out1);
        (out, removed_pos_opt)
    }

    /// x*y=k swap with fee in bps, supports a2b and b2a.
    /// Stream layout: [bool a2b, u64 amount_in, u64 min_amount_out]
    public fun swap(
        pool_signer: &signer,
        stream: &mut BCSStream,
        _sender: address
    ): (bool, u64, u64) acquires PoolState {
        let pool_addr = signer::address_of(pool_signer);
        let ps = borrow_global_mut<PoolState>(pool_addr);

        let a2b = deserialize_bool(stream);
        let amount_in = deserialize_u64(stream);
        let min_amount_out = deserialize_u64(stream);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let fee_bps = ps.fee_bps;
        let r0 = ps.amounts[0];
        let r1 = ps.amounts[1];
        assert!(r0 > 0 && r1 > 0, E_INSUFFICIENT_LIQUIDITY);

        let (rin, rout, idx_in, idx_out) = if (a2b) (r0, r1, 0, 1) else (r1, r0, 1, 0);

        // Apply fee to amount_in
        let fee_denom: u64 = 10_000;
        let amount_in_less_fee_u128 =
            ((amount_in as u128) * ((fee_denom - fee_bps) as u128)) / (fee_denom as u128);
        let amount_in_less_fee = amount_in_less_fee_u128 as u64;
        let fee_paid = amount_in - amount_in_less_fee;

        // x*y = k => out = floor( rout * dx' / (rin + dx') )
        let numer = (rout as u128) * (amount_in_less_fee as u128);
        let denom = (rin as u128) + (amount_in_less_fee as u128);
        let amount_out = (numer / denom) as u64;
        assert!(amount_out > 0, E_ZERO_AMOUNT);
        assert!(amount_out >= min_amount_out, E_SLIPPAGE);

        // Update reserves
        let rin_new  = rin + amount_in;
        let rout_new = rout - amount_out;

        *borrow_reserve_mut(ps, idx_in)  = rin_new;
        *borrow_reserve_mut(ps, idx_out) = rout_new;

        event::emit(Swapped {
            pool: pool_addr,
            a2b,
            amount_in,
            amount_out,
            fee_paid,
            reserve0_after: ps.amounts[0],
            reserve1_after: ps.amounts[1]
        });

        (a2b, amount_in, amount_out)
    }

    /*************** TESTS (state-based, no events) ***************/
    #[test_only] use aptos_framework::account;
    #[test_only] use aptos_std::bcs_stream as bs;

    /***** Helpers *****/
    #[test_only]
    fun mk_signer(addr: address): signer {
        account::create_account_for_test(addr)
    }

    #[test_only]
    fun mk_stream_add(a0: u64, a1: u64): BCSStream {
        let buf = to_bytes(&a0);
        let b1 = to_bytes(&a1);
        buf.append(b1);
        bs::new(buf)
    }

    #[test_only]
    fun mk_stream_remove(shares: u64): BCSStream {
        let buf = to_bytes(&shares);
        bs::new(buf)
    }

    #[test_only]
    fun mk_stream_swap(a2b: bool, amount_in: u64, min_out: u64): BCSStream {
        let buf = to_bytes(&a2b);
        let b1 = to_bytes(&amount_in);
        let b2 = to_bytes(&min_out);
        buf.append(b1);
        buf.append(b2);
        bs::new(buf)
    }

    #[test_only]
    fun expected_swap_out(rin: u64, rout: u64, fee_bps: u64, amount_in: u64): u64 {
        let fee_denom: u64 = 10_000;
        let dxp_u128 = ((amount_in as u128) * ((fee_denom - fee_bps) as u128)) / (fee_denom as u128);
        let dxp = dxp_u128 as u64;
        let numer = (rout as u128) * (dxp as u128);
        let denom = (rin as u128) + (dxp as u128);
        (numer / denom) as u64
    }

    /***** Tests *****/

    /// create_pool: happy path + initial state checks
    #[test]
    fun test_create_pool_happy_path() acquires PoolState {
        let pool = mk_signer(@0xB0B);
        let assets = vector::empty<address>();
        assets.push_back(@0xCAFE);
        assets.push_back(@0xBEEF);

        create_pool(&pool, assets, 30, @0x1);

        let pool_addr = signer::address_of(&pool);
        let ps = borrow_global<PoolState>(pool_addr);

        assert!(ps.fee_bps == 30, 0);
        assert!(ps.assets.length() == 2, 0);
        assert!(ps.amounts[0] == 0 && ps.amounts[1] == 0, 0);
        assert!(ps.lp_total_supply == 0, 0);
        assert!(ps.positions_count == 0, 0);
    }

    /// create_pool: various failures
    #[test, expected_failure(abort_code = E_POOL_ALREADY_EXISTS)]
    fun test_create_pool_twice_aborts() acquires PoolState {
        let pool = mk_signer(@0xB0B1);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 5, @0x1);

        let assets2 = vector::empty<address>();
        assets2.push_back(@0x3);
        assets2.push_back(@0x4);
        // second time on same pool address -> abort
        create_pool(&pool, assets2, 5, @0x1);
    }

    #[test, expected_failure(abort_code = E_NOT_TWO_ASSETS)]
    fun test_create_pool_requires_two_assets() acquires PoolState {
        let pool = mk_signer(@0xB0B2);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        create_pool(&pool, assets, 1, @0x1);
    }

    #[test, expected_failure(abort_code = E_IDENTICAL_ASSETS)]
    fun test_create_pool_identical_assets_aborts() acquires PoolState {
        let pool = mk_signer(@0xB0B3);
        let assets = vector::empty<address>();
        assets.push_back(@0xA);
        assets.push_back(@0xA);
        create_pool(&pool, assets, 1, @0x1);
    }

    #[test, expected_failure(abort_code = E_FEE_ZERO)]
    fun test_create_pool_fee_zero_aborts() acquires PoolState {
        let pool = mk_signer(@0xB0B4);
        let assets = vector::empty<address>();
        assets.push_back(@0xA);
        assets.push_back(@0xB);
        create_pool(&pool, assets, 0, @0x1);
    }

    #[test, expected_failure(abort_code = E_FEE_TOO_HIGH)]
    fun test_create_pool_fee_too_high_aborts() acquires PoolState {
        let pool = mk_signer(@0xB0B5);
        let assets = vector::empty<address>();
        assets.push_back(@0xA);
        assets.push_back(@0xB);
        // 10_000 bps = 100% -> invalid
        create_pool(&pool, assets, 10_000, @0x1);
    }

    /// add_liquidity (initial): shares = floor(sqrt(a0 * a1)), reserves updated, position minted
    #[test]
    fun test_add_liquidity_initial() acquires PoolState {
        let pool = mk_signer(@0xC0DE);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 30, @0x1);

        let amount0 = 1_000u64;
        let amount1 = 1_000u64;
        let s = mk_stream_add(amount0, amount1);
        let (added, pos_opt) = add_liquidity(&pool, option::none(), &mut s, @0x1);

        let pool_addr = signer::address_of(&pool);
        let ps = borrow_global<PoolState>(pool_addr);

        let expected_shares = sqrt_u128((amount0 as u128) * (amount1 as u128)) as u64;
        assert!(added[0] == amount0 && added[1] == amount1, 0);
        assert!(ps.amounts[0] == amount0 && ps.amounts[1] == amount1, 0);
        assert!(ps.lp_total_supply == expected_shares, 0);
        assert!(pos_opt.is_some(), 0);

        let id = pos_opt.destroy_some();
        let p = ps.positions.borrow(&id);
        assert!(p.value == expected_shares, 0);
        assert!(ps.positions_count == 1, 0);
    }

    /// add_liquidity (subsequent): proportional mint + use amounts; add to existing position
    #[test]
    fun test_add_liquidity_proportional_second_add() acquires PoolState {
        let pool = mk_signer(@0xC0D2);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 30, @0x1);

        // Initial 1000/1000 -> shares 1000
        let s0 = mk_stream_add(1_000, 1_000);
        let (_, pos_opt) = add_liquidity(&pool, option::none(), &mut s0, @0x1);
        let pid0 = pos_opt.destroy_some();

        // Second add (500, 1000) into SAME position
        let s1 = mk_stream_add(500, 1_000);
        let (_, none_id) = add_liquidity(&pool, option::some(pid0), &mut s1, @0x1);
        assert!(none_id.is_none(), 0);

        let pool_addr = signer::address_of(&pool);
        let ps = borrow_global<PoolState>(pool_addr);

        // Expected: shares minted = min(500*1000/1000, 1000*1000/1000) = min(500, 1000) = 500
        // Used a0 = 500, a1 = 500; Reserves -> 1500/1500, LP total -> 1500
        assert!(ps.amounts[0] == 1_500 && ps.amounts[1] == 1_500, 0);
        assert!(ps.lp_total_supply == 1_500, 0);

        let p = ps.positions.borrow(&pid0);
        assert!(p.value == 1_500, 0);
    }

    /// remove_liquidity: partial and then full burn; state reflects out amounts; position removal when zero
    #[test]
    fun test_remove_liquidity_partial_then_full() acquires PoolState {
        let pool = mk_signer(@0xC0D3);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 30, @0x1);

        // Seed: end at reserves 1500/1500, LP 1500, position 0 has 1500
        let s0 = mk_stream_add(1_000, 1_000);
        let (_, pos_opt) = add_liquidity(&pool, option::none(), &mut s0, @0x1);
        let pid0 = pos_opt.destroy_some();
        let s1 = mk_stream_add(500, 1_000);
        add_liquidity(&pool, option::some(pid0), &mut s1, @0x1);

        // Burn 750 (half) -> out 750/750, reserves -> 750/750, LP -> 750
        let r0 = mk_stream_remove(750);
        let (out_half, removed_none) = remove_liquidity(&pool, pid0, &mut r0, @0x1);
        assert!(removed_none.is_none(), 0);
        assert!(out_half[0] == 750 && out_half[1] == 750, 0);

        let pool_addr = signer::address_of(&pool);
        let ps1 = borrow_global<PoolState>(pool_addr);
        assert!(ps1.amounts[0] == 750 && ps1.amounts[1] == 750, 0);
        assert!(ps1.lp_total_supply == 750, 0);
        assert!(ps1.positions.borrow(&pid0).value == 750, 0);

        // Burn remaining 750 -> out 750/750, reserves -> 0/0, LP -> 0, position removed
        let r1 = mk_stream_remove(750);
        let (out_full, removed_some) = remove_liquidity(&pool, pid0, &mut r1, @0x1);
        assert!(out_full[0] == 750 && out_full[1] == 750, 0);
        let rid = removed_some.destroy_some();
        assert!(rid == pid0, 0);

        let ps2 = borrow_global<PoolState>(pool_addr);
        assert!(ps2.amounts[0] == 0 && ps2.amounts[1] == 0, 0);
        assert!(ps2.lp_total_supply == 0, 0);
        assert!(!ps2.positions.contains(&pid0), 0);
    }

    /// swap: a2b then b2a, check amount_out and reserves strictly by formula/state
    #[test]
    fun test_swap_a2b_then_b2a() acquires PoolState {
        let pool = mk_signer(@0xC0D4);
        let assets = vector::empty<address>();
        assets.push_back(@0xAA);
        assets.push_back(@0xBB);
        create_pool(&pool, assets, 30, @0x1);

        // Large symmetric liquidity
        let s0 = mk_stream_add(1_000_000, 1_000_000);
        add_liquidity(&pool, option::none(), &mut s0, @0x1);

        // a2b swap in 10_000
        let ss = mk_stream_swap(true, 10_000, 0);
        let (_a2b, _dx, dy) = swap(&pool, &mut ss, @0x1);

        let pool_addr = signer::address_of(&pool);
        let ps = borrow_global<PoolState>(pool_addr);
        let exp_a2b = expected_swap_out(1_000_000, 1_000_000, ps.fee_bps, 10_000);
        assert!(dy == exp_a2b, 0);
        assert!(ps.amounts[0] == 1_000_000 + 10_000, 0);
        assert!(ps.amounts[1] == 1_000_000 - exp_a2b, 0);

        // b2a swap in 20_000 on updated reserves
        let r0 = ps.amounts[0];
        let r1 = ps.amounts[1];

        let ss2 = mk_stream_swap(false, 20_000, 0);
        let (_b2a, _dx2, dy2) = swap(&pool, &mut ss2, @0x1);

        let ps2 = borrow_global<PoolState>(pool_addr);
        let exp_b2a = expected_swap_out(r1, r0, ps2.fee_bps, 20_000);
        assert!(dy2 == exp_b2a, 0);
        assert!(ps2.amounts[1] == r1 + 20_000, 0);
        assert!(ps2.amounts[0] == r0 - exp_b2a, 0);
    }

    /// swap: slippage guard aborts if min_amount_out too high
    #[test, expected_failure(abort_code = E_SLIPPAGE)]
    fun test_swap_slippage_abort() acquires PoolState {
        let pool = mk_signer(@0xC0D5);
        let assets = vector::empty<address>();
        assets.push_back(@0xAA);
        assets.push_back(@0xBB);
        create_pool(&pool, assets, 30, @0x1);

        let s0 = mk_stream_add(500_000, 500_000);
        add_liquidity(&pool, option::none(), &mut s0, @0x1);

        let pool_addr = signer::address_of(&pool);
        let ps = borrow_global<PoolState>(pool_addr);

        let want_in = 10_000u64;
        let exp_out = expected_swap_out(ps.amounts[0], ps.amounts[1], ps.fee_bps, want_in);
        // demand 1 more than possible
        let ss = mk_stream_swap(true, want_in, exp_out + 1);
        swap(&pool, &mut ss, @0x1);
    }

    /// add_liquidity with non-existent position id aborts
    #[test, expected_failure(abort_code = E_POSITION_NOT_FOUND)]
    fun test_add_liquidity_bad_position_aborts() acquires PoolState {
        let pool = mk_signer(@0xC0D6);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 30, @0x1);

        let s0 = mk_stream_add(1_000, 1_000);
        add_liquidity(&pool, option::none(), &mut s0, @0x1);

        // Position 999 not present
        let s1 = mk_stream_add(10, 10);
        add_liquidity(&pool, option::some(999), &mut s1, @0x1);
    }

    /// remove_liquidity with too many shares aborts
    #[test, expected_failure(abort_code = E_INSUFFICIENT_LIQUIDITY)]
    fun test_remove_liquidity_too_much_aborts() acquires PoolState {
        let pool = mk_signer(@0xC0D7);
        let assets = vector::empty<address>();
        assets.push_back(@0x1);
        assets.push_back(@0x2);
        create_pool(&pool, assets, 30, @0x1);

        let s0 = mk_stream_add(1_000, 1_000);
        let (_, pos_opt) = add_liquidity(&pool, option::none(), &mut s0, @0x1);
        let pid0 = pos_opt.destroy_some();

        // Try to burn > owned
        let r = mk_stream_remove(2_000);
        remove_liquidity(&pool, pid0, &mut r, @0x1);
    }
}
