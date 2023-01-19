#[test_only]
module ipx::dex_tests {
    use sui::coin::{mint_for_testing as mint, destroy_for_testing as burn};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::math;

    use ipx::dex::{Self, Storage};
    use ipx::test_utils::{people, scenario};

    struct Ether {}
    struct USDC {}

    fun test_create_pool_(test: &mut Scenario) {
      let (alice, _) = people();

      let ether_value = 100;
      let usdc_value = 150000;
      let lp_coin_initial_user_balance = math::sqrt(ether_value * usdc_value);

      next_tx(test, alice);
      {
        dex::init_for_testing(ctx(test));
      };

      next_tx(test, alice);
      {
        let storage = test::take_shared<Storage>(test);

        let lp_coin = dex::create_pool(
          &mut storage,
          mint<Ether>(ether_value, ctx(test)),
          mint<USDC>(usdc_value, ctx(test)),
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
        assert!(ether_reserves == ether_value, 0);
        assert!(usdc_reserves == usdc_value, 0);

        test::return_shared(storage);
      }
    }

    #[test] 
    fun test_create_pool() {
        let scenario = scenario();
        test_create_pool_(&mut scenario);
        test::end(scenario);
    }

}