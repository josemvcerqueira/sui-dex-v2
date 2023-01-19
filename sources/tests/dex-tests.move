#[test_only]
module ipx::dex_tests {
    use sui::coin::{mint_for_testing as mint, destroy_for_testing as burn};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::math;

    use ipx::dex::{Self, Storage, AdminCap};
    use ipx::test_utils::{people, scenario};

    struct Ether {}
    struct USDC {}

    const INITIAL_ETHER_VALUE: u64 = 100;
    const INITIAL_USDC_VALUE: u64 = 150000;
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