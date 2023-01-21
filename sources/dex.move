module ipx::dex {

  use std::string::{String}; 

  use sui::tx_context::{Self, TxContext};
  use sui::coin::{Self, Coin};
  use sui::balance::{Self, Supply, Balance};
  use sui::object::{Self,UID, ID};
  use sui::transfer;
  use sui::math;
  use sui::bag::{Self, Bag};
  use sui::event;


  use ipx::utils;
  use ipx::u256;


  const DEV: address = @dev;
  const ZERO_ACCOUNT: address = @zero;
  const MAX_POOL_COIN_AMOUNT: u64 = {
        18446744073709551615 / 10000
    };
  const MINIMUM_LIQUIDITY: u64 = 10;
  const PRECISION: u64 = 100000;
  const FEE_PERCENT: u64 = 300;  

  const ERROR_UNSORTED_COINS: u64 = 1;
  const ERROR_CREATE_PAIR_ZERO_VALUE: u64 = 2;
  const ERROR_POOL_IS_FULL: u64 = 3;
  const ERROR_POOL_EXISTS: u64 = 4;
  const ERROR_ZERO_VALUE_SWAP: u64 = 5;
  const ERROR_EMPTY_POOL: u64 = 6;
  const ERROR_SLIPPAGE: u64 = 7;
  const ERROR_ADD_LIQUIDITY_ZERO_AMOUNT: u64 = 8;
  const ERROR_REMOVE_LIQUIDITY_ZERO_AMOUNT: u64 = 9;

    struct AdminCap has key {
      id: UID,
    }

    struct Storage has key {
      id: UID,
      pools: Bag,
      fee_to: address
    }

    struct LPCoin<phantom X, phantom Y> has drop, store {}

    struct Pool<phantom X, phantom Y> has key, store {
        id: UID,
        k_last: u64,
        lp_coin_supply: Supply<LPCoin<X, Y>>,
        balance_x: Balance<X>,
        balance_y: Balance<Y>
    }

    // Events
    struct PoolCreated<phantom P> has copy, drop {
      id: ID,
      shares: u64,
      value_x: u64,
      value_y: u64,
      sender: address
    }

    struct SwapTokenX<phantom X, phantom Y> has copy, drop {
      id: ID,
      sender: address,
      coin_x_in: u64,
      coin_y_out: u64
    }

    struct SwapTokenY<phantom X, phantom Y> has copy, drop {
      id: ID,
      sender: address,
      coin_y_in: u64,
      coin_x_out: u64
    }

    struct AddLiquidity<phantom P> has copy, drop {
      id: ID,
      sender: address,
      coin_x_amount: u64,
      coin_y_amount: u64,
      shares_minted: u64
    }

    struct RemoveLiquidity<phantom P> has copy, drop {
      id: ID,
      sender: address,
      coin_x_out: u64,
      coin_y_out: u64,
      shares_destroyed: u64
    }



    fun init(ctx: &mut TxContext) {
      // Give administrator capabilities to the deployer
      // He has the ability to update the fee_to key on the Storage
      transfer::transfer(
        AdminCap { 
          id: object::new(ctx)
        }, 
        tx_context::sender(ctx)
        );

      // Share the Storage object
      transfer::share_object(
         Storage {
           id: object::new(ctx),
           pools: bag::new(ctx),
           fee_to: DEV
         }
      );
    }

    public fun create_pool<X, Y>(
      storage: &mut Storage,
      coin_x: Coin<X>,
      coin_y: Coin<Y>,
      ctx: &mut TxContext
    ): Coin<LPCoin<X, Y>> {
      assert!(utils::are_coins_sorted<X, Y>(), ERROR_UNSORTED_COINS);

      // Sort the coins and get their values
      let coin_x_value = coin::value(&coin_x);
      let coin_y_value = coin::value(&coin_y);

      assert!(coin_x_value != 0 && coin_y_value != 0, ERROR_CREATE_PAIR_ZERO_VALUE);    
      assert!(MAX_POOL_COIN_AMOUNT > coin_x_value && MAX_POOL_COIN_AMOUNT > coin_y_value, ERROR_POOL_IS_FULL);

      let lp_coin_name = utils::get_lp_coin_name<X, Y>();

      assert!(!bag::contains(&storage.pools, lp_coin_name), ERROR_POOL_EXISTS);

        let k = coin_x_value * coin_y_value;
        let shares = math::sqrt(k);

        let supply = balance::create_supply(LPCoin<X, Y> {});
        let min_liquidity_balance = balance::increase_supply(&mut supply, MINIMUM_LIQUIDITY);
        let sender_balance = balance::increase_supply(&mut supply, shares);

        transfer::transfer(coin::from_balance(min_liquidity_balance, ctx), ZERO_ACCOUNT);

        let pool_id = object::new(ctx);

        event::emit(
          PoolCreated<Pool<X, Y>> {
            id: object::uid_to_inner(&pool_id),
            shares,
            value_x: coin_x_value,
            value_y: coin_y_value,
            sender: tx_context::sender(ctx)
          }
        );

        bag::add(
          &mut storage.pools,
          lp_coin_name,
          Pool {
            id: pool_id,
            k_last: k,
            lp_coin_supply: supply,
            balance_x: coin::into_balance<X>(coin_x),
            balance_y: coin::into_balance<Y>(coin_y)
            }
        );

        coin::from_balance(sender_balance, ctx)
    }

    public fun swap<X, Y>(
      storage: &mut Storage,
      coin_x: Coin<X>,
      coin_y: Coin<Y>,
      coin_out_min_value: u64,
      ctx: &mut TxContext
      ): (Coin<X>, Coin<Y>) {
      assert!(utils::are_coins_sorted<X, Y>(), ERROR_UNSORTED_COINS);

       let is_coin_x_value_zero = coin::value(&coin_x) == 0;

        assert!(!is_coin_x_value_zero || coin::value(&coin_y) != 0, ERROR_ZERO_VALUE_SWAP);

        let pool = borrow_mut_pool<X, Y>(storage);

        if (is_coin_x_value_zero) {
          coin::destroy_zero(coin_x);
          let coin_x = swap_token_y(pool, coin_y, coin_out_min_value, ctx);
           (coin_x, coin::zero<Y>(ctx)) 
        } else {
          coin::destroy_zero(coin_y);
          let coin_y = swap_token_x(pool, coin_x, coin_out_min_value, ctx);
          (coin::zero<X>(ctx), coin_y) 
        }
      }

      public fun one_hop_swap<X, Y, Z>(
        storage: &mut Storage,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        coin_out_min_value: u64,
        ctx: &mut TxContext
      ): (Coin<X>, Coin<Y>) {

        let is_coin_x_value_zero = coin::value(&coin_x) == 0;

        assert!(!is_coin_x_value_zero || coin::value(&coin_y) != 0, ERROR_ZERO_VALUE_SWAP);

        // Y -> Z -> X
        if (is_coin_x_value_zero) {
           coin::destroy_zero(coin_x);

           if (utils::are_coins_sorted<Y, Z>()) {
            let coin_z = swap_token_x(
              borrow_mut_pool<Y, Z>(storage),
              coin_y, 
              0, 
              ctx
            );

            if (utils::are_coins_sorted<X, Z>()) {
            let coin_x = swap_token_y(
              borrow_mut_pool<X, Z>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );

            (coin_x, coin::zero<Y>(ctx))
            
            } else {
            let coin_x = swap_token_x(
              borrow_mut_pool<Z, X>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
             (coin_x, coin::zero<Y>(ctx))
              }
           } else {
            let coin_z = swap_token_y(
              borrow_mut_pool<Z, Y>(storage),
              coin_y, 
              0, 
              ctx
            );

          if (utils::are_coins_sorted<X, Z>()) {
            let coin_x = swap_token_y(
              borrow_mut_pool<X, Z>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
            (coin_x, coin::zero<Y>(ctx))
            } else {
            let coin_x = swap_token_x(
              borrow_mut_pool<Z, X>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
            (coin_x, coin::zero<Y>(ctx))
            }
           }

        // X -> Z -> Y
        } else {
            coin::destroy_zero(coin_y);

           if (utils::are_coins_sorted<X, Z>()) {
            let coin_z = swap_token_x(
              borrow_mut_pool<X, Z>(storage),
              coin_x, 
              0, 
              ctx
            );

          if (utils::are_coins_sorted<Y, Z>()) {
            let coin_y = swap_token_y(
              borrow_mut_pool<Y, Z>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );

            (coin::zero<X>(ctx), coin_y)
            
            } else {
            let coin_y = swap_token_x(
              borrow_mut_pool<Z, Y>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
             (coin::zero<X>(ctx), coin_y)
              }
           } else {
            let coin_z = swap_token_y(
              borrow_mut_pool<Z, X>(storage),
              coin_x, 
              0, 
              ctx
            );

          if (utils::are_coins_sorted<Y, Z>()) {
            let coin_y = swap_token_y(
              borrow_mut_pool<Y, Z>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
            (coin::zero<X>(ctx), coin_y)
            } else {
            let coin_y = swap_token_x(
              borrow_mut_pool<Z, Y>(storage),
              coin_z, 
              coin_out_min_value, 
              ctx
            );
            (coin::zero<X>(ctx), coin_y)
              }
           }
        }
      }

    
    public fun add_liquidity<X, Y>(   
      storage: &mut Storage,
      coin_x: Coin<X>,
      coin_y: Coin<Y>,
      ctx: &mut TxContext
      ): Coin<LPCoin<X, Y>> {
        assert!(utils::are_coins_sorted<X, Y>(), ERROR_UNSORTED_COINS);

        let coin_x_value = coin::value(&coin_x);
        let coin_y_value = coin::value(&coin_y);
        
        let fee_to = storage.fee_to;
        let pool = borrow_mut_pool<X, Y>(storage);

        let is_fee_on = mint_fee(pool, fee_to, ctx);

        assert!(coin_x_value != 0 && coin_x_value != 0, ERROR_ADD_LIQUIDITY_ZERO_AMOUNT);

        let (token_x_reserve, token_y_reserve, supply) = get_amounts(pool);

        let share_to_mint = math::min(
          (coin_x_value * supply) / token_x_reserve,
          (coin_y_value * supply) / token_y_reserve
        );

        let new_reserve_x = balance::join(&mut pool.balance_x, coin::into_balance(coin_x));
        let new_reserve_y = balance::join(&mut pool.balance_y, coin::into_balance(coin_y));

        assert!(MAX_POOL_COIN_AMOUNT >= new_reserve_x, ERROR_POOL_IS_FULL);
        assert!(MAX_POOL_COIN_AMOUNT >= new_reserve_y, ERROR_POOL_IS_FULL);

        event::emit(
          AddLiquidity<Pool<X, Y>> {
          id: object:: uid_to_inner(&pool.id), 
          sender: tx_context::sender(ctx), 
          coin_x_amount: coin_x_value, 
          coin_y_amount: coin_y_value,
          shares_minted: share_to_mint
          }
        );

        if (is_fee_on) pool.k_last = new_reserve_x * new_reserve_y;

        coin::from_balance(balance::increase_supply(&mut pool.lp_coin_supply, share_to_mint), ctx)
      }

    public fun remove_liquidity<X, Y>(   
      storage: &mut Storage,
      lp_coin: Coin<LPCoin<X, Y>>,
      ctx: &mut TxContext
      ): (Coin<X>, Coin<Y>) {
        assert!(utils::are_coins_sorted<X, Y>(), ERROR_UNSORTED_COINS);
        let lp_coin_value = coin::value(&lp_coin);

        assert!(lp_coin_value != 0, ERROR_REMOVE_LIQUIDITY_ZERO_AMOUNT);

        let fee_to = storage.fee_to;
        let pool = borrow_mut_pool<X, Y>(storage);

        let is_fee_on = mint_fee(pool, fee_to, ctx);

        let (token_x_reserve, token_y_reserve, lp_coin_supply) = get_amounts(pool);

        let coin_x_removed = (lp_coin_value * token_x_reserve) / lp_coin_supply;
        let coin_y_removed = (lp_coin_value * token_y_reserve) / lp_coin_supply;

        balance::decrease_supply(&mut pool.lp_coin_supply, coin::into_balance(lp_coin));

        event::emit(
          RemoveLiquidity<Pool<X, Y>> {
          id: object:: uid_to_inner(&pool.id), 
          sender: tx_context::sender(ctx), 
          coin_x_out: coin_x_removed,
          coin_y_out: coin_y_removed,
          shares_destroyed: lp_coin_value
          }
        );

        if (is_fee_on) pool.k_last = (token_x_reserve - coin_x_removed) * (token_y_reserve - coin_y_removed);

        (
          coin::take(&mut pool.balance_x, coin_x_removed, ctx),
          coin::take(&mut pool.balance_y, coin_y_removed, ctx),
        )
      }

    public fun borrow_pool<X, Y>(storage: &Storage): &Pool<X, Y> {
      bag::borrow<String, Pool<X, Y>>(&storage.pools, utils::get_lp_coin_name<X, Y>())
    }

    public fun is_pool_deployed<X, Y>(storage: &Storage):bool {
      bag::contains(&storage.pools, utils::get_lp_coin_name<X, Y>())
    }

    public fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            balance::value(&pool.balance_x),
            balance::value(&pool.balance_y),
            balance::supply_value(&pool.lp_coin_supply)
        )
    }          

    fun borrow_mut_pool<X, Y>(storage: &mut Storage): &mut Pool<X, Y> {
      bag::borrow_mut<String, Pool<X, Y>>(&mut storage.pools, utils::get_lp_coin_name<X, Y>())
    }   

    fun calculate_value_out(coin_in_amount: u64, balance_in: u64, balance_out:u64):u64 {
        let precision_u256 = u256::from_u64(PRECISION);
        let token_in_u256 = u256::from_u64(coin_in_amount);

        let token_in_amount_minus_fees_adjusted = u256::sub(token_in_u256, 
        u256::div(
          u256::mul(token_in_u256, u256::from_u64(FEE_PERCENT)),
          precision_u256)
          );

        let numerator = u256::mul(u256::from_u64(balance_out), token_in_amount_minus_fees_adjusted);
        let denominator = u256::add(u256::from_u64(balance_in), token_in_amount_minus_fees_adjusted);

        u256::as_u64(u256::div(numerator, denominator))
    }   

    fun swap_token_x<X, Y>(
      pool: &mut Pool<X, Y>, 
      coin_x: Coin<X>,
      coin_y_min_value: u64,
      ctx: &mut TxContext
      ): Coin<Y> {
        assert!(coin::value(&coin_x) != 0, ERROR_ZERO_VALUE_SWAP);

        let coin_x_balance = coin::into_balance(coin_x);

        let (coin_x_reserve, coin_y_reserve, _) = get_amounts(pool);  

        assert!(coin_x_reserve != 0 && coin_y_reserve != 0, ERROR_EMPTY_POOL);

        let coin_x_value = balance::value(&coin_x_balance);
        
        let coin_y_value = calculate_value_out(coin_x_value, coin_x_reserve, coin_y_reserve);

        assert!(coin_y_value >=  coin_y_min_value, ERROR_SLIPPAGE);

        event::emit(
          SwapTokenX<X, Y> {
            id: object:: uid_to_inner(&pool.id), 
            sender: tx_context::sender(ctx),
            coin_x_in: coin_x_value, 
            coin_y_out: coin_y_value 
            }
          );

        balance::join(&mut pool.balance_x, coin_x_balance);
        coin::take(&mut pool.balance_y, coin_y_value, ctx)
      }

    fun swap_token_y<X, Y>(
      pool: &mut Pool<X, Y>, 
      coin_y: Coin<Y>,
      coin_x_min_value: u64,
      ctx: &mut TxContext
      ): Coin<X> {
        assert!(coin::value(&coin_y) != 0, ERROR_ZERO_VALUE_SWAP);

        let coin_y_balance = coin::into_balance(coin_y);

        let (coin_x_reserve, coin_y_reserve, _) = get_amounts(pool);  

        assert!(coin_x_reserve != 0 && coin_y_reserve != 0, ERROR_EMPTY_POOL);

        let coin_y_value = balance::value(&coin_y_balance);

        let coin_x_value = calculate_value_out(coin_y_value, coin_y_reserve, coin_x_reserve);

        assert!(coin_x_value >=  coin_x_min_value, ERROR_SLIPPAGE);

        event::emit(
          SwapTokenY<X, Y> {
            id: object:: uid_to_inner(&pool.id), 
            sender: tx_context::sender(ctx),
            coin_y_in: coin_y_value, 
            coin_x_out: coin_x_value 
            }
          );

        balance::join(&mut pool.balance_y, coin_y_balance);
        coin::take(&mut pool.balance_x, coin_x_value, ctx)
      }

      fun mint_fee<X, Y>(pool: &mut Pool<X, Y>, fee_to: address, ctx: &mut TxContext): bool {
          let is_fee_on = fee_to != ZERO_ACCOUNT;

          if (is_fee_on) {
            if (pool.k_last != 0) {
              let root_k = math::sqrt(balance::value(&pool.balance_x) * balance::value(&pool.balance_y));
              let root_k_last = math::sqrt(pool.k_last);

              if (root_k > root_k_last) {
                let numerator = balance::supply_value(&pool.lp_coin_supply) * (root_k - root_k_last);
                let denominator = (root_k * 5) + root_k_last;
                let liquidity = numerator / denominator;
                if (liquidity != 0) {
                  let new_balance = balance::increase_supply(&mut pool.lp_coin_supply, liquidity);
                  let new_coins = coin::from_balance(new_balance, ctx);
                  transfer::transfer(new_coins, fee_to);
                }
              }
            };
          } else if (pool.k_last > 0) {
            pool.k_last = 0;
          };

       is_fee_on
    }

    entry public fun update_fee_to(
      _:&AdminCap, 
      storage: &mut Storage,
      new_fee_to: address
       ) {
      storage.fee_to = new_fee_to;
    }

    entry public fun transfer_admin_cap(
      admin_cap: AdminCap,
      new_admin: address
    ) {
      transfer::transfer(admin_cap, new_admin);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun get_fee_to(storage: &Storage,): address {
      storage.fee_to
    }

    #[test_only]
    public fun get_k_last<X, Y>(storage: &mut Storage): u64 {
      let pool = borrow_mut_pool<X, Y>(storage);
      pool.k_last
    }
}

