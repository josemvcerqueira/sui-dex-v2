#[test_only]
module ipx::dex_tests {

    use sui::coin::{Self, mint_for_testing as mint, destroy_for_testing as burn};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::sui::{SUI};
    use sui::math;

    use ipx::dex::{Self, Storage, AdminCap, LPCoin};
    use ipx::test_utils::{people, scenario};

    struct Ether {}
    struct USDC {}

    const INITIAL_ETHER_VALUE: u64 = 100000;
    const INITIAL_USDC_VALUE: u64 = 150000000;
    const ZERO_ACCOUNT: address = @0x0;

    fun test_create_pool_(test: &mut Scenario) {
      let (alice, _) = people();

      let lp_coin_initial_user_balance = math::sqrt(INITIAL_ETHER_VALUE * INITIAL_USDC_VALUE);

      next_tx(test, alice);
      {
        dex::init_for_testing(ctx(test));
      };

      next_tx(test, alice);
      {
        let storage = test::take_shared<Storage>(test);

        let lp_coin = dex::create_pool(
          &mut storage,
          mint<Ether>(INITIAL_ETHER_VALUE, ctx(test)),
          mint<USDC>(INITIAL_USDC_VALUE, ctx(test)),
          ctx(test)
        );

        assert!(burn(lp_coin) == lp_coin_initial_user_balance, 0);
        test::return_shared(storage);
      };

      next_tx(test, alice);
      {
        let storage = test::take_shared<Storage>(test);
        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (ether_reserves, usdc_reserves, supply) = dex::get_amounts(pool);

        assert!(supply == lp_coin_initial_user_balance + 10, 0);
        assert!(ether_reserves == INITIAL_ETHER_VALUE, 0);
        assert!(usdc_reserves == INITIAL_USDC_VALUE, 0);

        test::return_shared(storage);
      }
    }

    #[test] 
    fun test_create_pool() {
        let scenario = scenario();
        test_create_pool_(&mut scenario);
        test::end(scenario);
    }

    fun test_add_liquidity_(test: &mut Scenario) {
        test_create_pool_(test);
        remove_fee(test);

        let (_, bob) = people();

        let ether_value = INITIAL_ETHER_VALUE / 10;
        let usdc_value = INITIAL_USDC_VALUE / 10;

        next_tx(test, bob);
        {
        let storage = test::take_shared<Storage>(test);
        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (_, _, supply) = dex::get_amounts(pool);

        let lp_coin = dex::add_liquidity(
          &mut storage,
          mint<Ether>(ether_value, ctx(test)),
          mint<USDC>(usdc_value, ctx(test)),
          ctx(test)
          );

        let pool = dex::borrow_pool<Ether, USDC>(&storage); 
        let (ether_reserves, usdc_reserves, _) = dex::get_amounts(pool); 

        assert!(burn(lp_coin)== supply / 10, 0);
        assert!(ether_reserves == INITIAL_ETHER_VALUE + ether_value, 0);
        assert!(usdc_reserves == INITIAL_USDC_VALUE + usdc_value, 0);
        
        test::return_shared(storage);
        }
    }


    #[test]
    fun test_add_liquidity() {
        let scenario = scenario();
        test_add_liquidity_(&mut scenario);
        test::end(scenario);
    }

    fun test_remove_liquidity_(test: &mut Scenario) {
        test_create_pool_(test);
        remove_fee(test);

        let (_, bob) = people();

        let ether_value = INITIAL_ETHER_VALUE / 10;
        let usdc_value = INITIAL_USDC_VALUE / 10;

        next_tx(test, bob);
        {
          let storage = test::take_shared<Storage>(test);

          let lp_coin = dex::add_liquidity(
            &mut storage,
            mint<Ether>(ether_value, ctx(test)),
            mint<USDC>(usdc_value, ctx(test)),
            ctx(test)
          );

          let pool = dex::borrow_pool<Ether, USDC>(&storage);
          let (ether_reserves_1, usdc_reserves_1, supply_1) = dex::get_amounts(pool);

          let lp_coin_value = coin::value(&lp_coin);

          let (ether, usdc) = dex::remove_liquidity(
              &mut storage,
              lp_coin,
              ctx(test)
          );

          let pool = dex::borrow_pool<Ether, USDC>(&storage);
          let (ether_reserves_2, usdc_reserves_2, supply_2) = dex::get_amounts(pool);

          // rounding issues
          assert!(burn(ether) == 9999, 0);
          assert!(burn(usdc) == 14999989, 0);
          assert!(supply_1 == supply_2 + lp_coin_value, 0);
          assert!(ether_reserves_1 == ether_reserves_2 + 9999, 0);
          assert!(usdc_reserves_1 == usdc_reserves_2 + 14999989, 0);

          test::return_shared(storage);
        }
    }

    #[test]
    fun test_remove_liquidity() {
        let scenario = scenario();
        test_remove_liquidity_(&mut scenario);
        test::end(scenario);
    }

    fun test_add_liquidity_with_fee_(test: &mut Scenario) {
        test_create_pool_(test);

       let ether_value = INITIAL_ETHER_VALUE / 10;
       let usdc_value = INITIAL_USDC_VALUE / 10;

       let (_, bob) = people();
        
       next_tx(test, bob);
       {
        let storage = test::take_shared<Storage>(test);

        let (ether, usdc) = dex::swap(
          &mut storage,
          mint<Ether>(ether_value, ctx(test)),
          coin::zero<USDC>(ctx(test)),
          0,
          ctx(test)
        );

        assert!(burn(ether) == 0, 0);
        assert!(burn(usdc) != 0, 0);

        test::return_shared(storage); 
       };

       next_tx(test, bob);
       {
        let storage = test::take_shared<Storage>(test);

        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (ether_reserves_1, usdc_reserves_1, supply_1) = dex::get_amounts(pool);
        let k_last = dex::get_k_last<Ether, USDC>(&mut storage);

        let root_k = math::sqrt(ether_reserves_1 * usdc_reserves_1);
        let root_k_last = math::sqrt(k_last);

        let numerator = supply_1 * (root_k - root_k_last);
        let denominator  = (root_k * 5) + root_k_last;
        let fee = numerator / denominator;

        let lp_coin = dex::add_liquidity(
          &mut storage,
          mint<Ether>(ether_value, ctx(test)),
          mint<USDC>(usdc_value, ctx(test)),
          ctx(test)
        );

        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (_, _, supply_2) = dex::get_amounts(pool);

        assert!(fee > 0, 0);
        assert!(burn(lp_coin) + fee + supply_1 == supply_2, 0);
        
        test::return_shared(storage);
       }
    }

    #[test]
    fun test_add_liquidity_with_fee() {
        let scenario = scenario();
        test_add_liquidity_with_fee_(&mut scenario);
        test::end(scenario);
    }

    fun test_remove_liquidity_with_fee_(test: &mut Scenario) {
        test_create_pool_(test);

       let (_, bob) = people();
        
       next_tx(test, bob);
        {
        let storage = test::take_shared<Storage>(test);

        let (ether, usdc) = dex::swap(
          &mut storage,
          mint<Ether>(INITIAL_ETHER_VALUE / 10, ctx(test)),
          coin::zero<USDC>(ctx(test)),
          0,
          ctx(test)
        );

        assert!(burn(ether) == 0, 0);
        assert!(burn(usdc) != 0, 0);

        test::return_shared(storage); 
       };

       next_tx(test, bob);
       {
        let storage = test::take_shared<Storage>(test);

        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (ether_reserves_1, usdc_reserves_1, supply_1) = dex::get_amounts(pool);
        let k_last = dex::get_k_last<Ether, USDC>(&mut storage);

        let root_k = math::sqrt(ether_reserves_1 * usdc_reserves_1);
        let root_k_last = math::sqrt(k_last);

        let numerator = supply_1 * (root_k - root_k_last);
        let denominator  = (root_k * 5) + root_k_last;
        let fee = numerator / denominator;

        let (ether, usdc) = dex::remove_liquidity(
          &mut storage,
          mint<LPCoin<Ether, USDC>>(30000, ctx(test)),
          ctx(test)
        );

        burn(ether);
        burn(usdc);

        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (_, _, supply_2) = dex::get_amounts(pool);

        assert!(fee > 0, 0);
        assert!(supply_2 == supply_1 + fee - 30000, 0);

        test::return_shared(storage);
       }
    }

    #[test]
    fun test_remove_liquidity_with_fee() {
        let scenario = scenario();
        test_remove_liquidity_with_fee_(&mut scenario);
        test::end(scenario);
    }

    fun test_one_hop_swap_(test: &mut Scenario) {
       test_create_pool_(test);

       let (_, bob) = people();
        
       next_tx(test, bob);
       {
        let storage = test::take_shared<Storage>(test);

        let lp_coin = dex::create_pool(
          &mut storage,
          mint<Ether>(100000, ctx(test)),
          mint<SUI>(3000000, ctx(test)),
          ctx(test)
        );

        burn(lp_coin);
        test::return_shared(storage);
       };

       next_tx(test, bob);
       {
        let storage = test::take_shared<Storage>(test);

        let sui_swap_amount = 300000;

        let pool = dex::borrow_pool<Ether, SUI>(&storage);
        let (ether_reserves, sui_reserves, _) = dex::get_amounts(pool);

        let token_in_amount = sui_swap_amount - ((sui_swap_amount * 300) / 100000);
        let ether_amount_received = (ether_reserves * token_in_amount) / (token_in_amount + sui_reserves);

        let pool = dex::borrow_pool<Ether, USDC>(&storage);
        let (ether_reserves, usdc_reserves, _) = dex::get_amounts(pool);

        let token_in_amount = ether_amount_received - ((ether_amount_received * 300) / 100000);
        let usdc_amount_received = (usdc_reserves * token_in_amount) / (ether_reserves + token_in_amount);

        let (sui, usdc) = dex::one_hop_swap<SUI, USDC, Ether>(
          &mut storage,
          mint<SUI>(sui_swap_amount, ctx(test)),
          mint<USDC>(0, ctx(test)),
          0,
          ctx(test)
        );

        assert!(burn(usdc) == usdc_amount_received, 0);
        assert!(burn(sui) == 0, 0);

        test::return_shared(storage);
       }
    }

    #[test]
    fun test_one_hop_swap() {
        let scenario = scenario();
        test_one_hop_swap_(&mut scenario);
        test::end(scenario);
    }

    fun remove_fee(test: &mut Scenario) {
      let (owner, _) = people();
        
       next_tx(test, owner);
       {
        let admin_cap = test::take_from_sender<AdminCap>(test);
        let storage = test::take_shared<Storage>(test);

        dex::update_fee_to(&admin_cap, &mut storage, ZERO_ACCOUNT);

        test::return_shared(storage);
        test::return_to_sender(test, admin_cap)
       }
    }
}