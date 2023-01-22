module ipx::interface {
  use std::vector;

  use sui::coin::{Self, Coin};
  use sui::tx_context::{Self, TxContext};
  use sui::transfer;
  use sui::pay;

  use ipx::dex::{Self, Storage, LPCoin};
  use ipx::utils;

  const ERROR_UNSORTED_COINS: u64 = 1;

  entry public fun create_pool<X, Y>(
      storage: &mut Storage,
      vector_x: vector<Coin<X>>,
      vector_y: vector<Coin<Y>>,
      ctx: &mut TxContext
  ) {
    let coin_x = coin::zero<X>(ctx);
    let coin_y = coin::zero<Y>(ctx);

    pay::join_vec(&mut coin_x, vector_x);
    pay::join_vec(&mut coin_y, vector_y);

    transfer::transfer(
      dex::create_pool(
        storage,
        coin_x,
        coin_y,
        ctx
      ),
      tx_context::sender(ctx)
    )
  }

  entry public fun swap<X, Y>(
    storage: &mut Storage,
    vector_x: vector<Coin<X>>,
    vector_y: vector<Coin<Y>>,
    coin_in_value: u64,
    coin_out_min_value: u64,
    ctx: &mut TxContext
  ) {
    let (coin_x, coin_y) = handle_swap_vectors(vector_x, vector_y, coin_in_value, ctx);

    let (coin_x, coin_y) = dex::swap(
      storage,
      coin_x,
      coin_y,
      coin_out_min_value,
      ctx
    );

    safe_transfer(coin_x, ctx);
    safe_transfer(coin_y, ctx);
  }

  entry public fun one_hop_swap<X, Y, Z>(
    storage: &mut Storage,
    vector_x: vector<Coin<X>>,
    vector_y: vector<Coin<Y>>,
    coin_in_value: u64,
    coin_out_min_value: u64,
    ctx: &mut TxContext
  ) {
    let (coin_x, coin_y) = handle_swap_vectors(vector_x, vector_y, coin_in_value, ctx);

    let (coin_x, coin_y) = dex::one_hop_swap<X, Y, Z>(
      storage,
      coin_x,
      coin_y,
      coin_out_min_value,
      ctx
    );

    safe_transfer(coin_x, ctx);
    safe_transfer(coin_y, ctx);
  }

  entry public fun two_hop_swap<X, Y, B1, B2>(
    storage: &mut Storage,
    vector_x: vector<Coin<X>>,
    vector_y: vector<Coin<Y>>,
    coin_in_value: u64,
    coin_out_min_value: u64,
    ctx: &mut TxContext
  ) {
    let (coin_x, coin_y) = handle_swap_vectors(vector_x, vector_y, coin_in_value, ctx);
    let sender = tx_context::sender(ctx);

    // Y -> B1 -> B2 -> X
    if (coin::value(&coin_x) == 0) {

    if (utils::are_coins_sorted<Y, B1>()) {
      let (coin_y, coin_b1) = dex::swap(
        storage,
        coin_y,
        coin::zero<B1>(ctx),
        0,
        ctx
      );

      let (coin_b1, coin_x) = dex::one_hop_swap<B1, X, B2>(
        storage,
        coin_b1,
        coin_x,
        coin_out_min_value,
        ctx
      );

      coin::destroy_zero(coin_y);
      coin::destroy_zero(coin_b1);
      transfer::transfer(coin_x, sender);
    } else {
      let (coin_b1, coin_y) = dex::swap(
        storage,
        coin::zero<B1>(ctx),
        coin_y,
        0,
        ctx
      );

      let (coin_b1, coin_x) = dex::one_hop_swap<B1, X, B2>(
        storage,
        coin_b1,
        coin_x,
        coin_out_min_value,
        ctx
      );

      coin::destroy_zero(coin_y);
      coin::destroy_zero(coin_b1);
      transfer::transfer(coin_x, sender);
    }  

    // X -> B1 -> B2 -> Y
    } else {
      if (utils::are_coins_sorted<X, B1>()) {
        let (coin_x, coin_b1) = dex::swap(
          storage,
          coin_x,
          coin::zero<B1>(ctx),
          0,
          ctx
        );

       let (coin_b1, coin_y) = dex::one_hop_swap<B1, Y, B2>(
        storage,
        coin_b1,
        coin_y,
        coin_out_min_value,
        ctx
      );

      coin::destroy_zero(coin_x);
      coin::destroy_zero(coin_b1);
      transfer::transfer(coin_y, sender);
      } else {
        let (coin_b1, coin_x) = dex::swap(
          storage,
          coin::zero<B1>(ctx),
          coin_x,
          0,
          ctx
        );

       let (coin_b1, coin_y) = dex::one_hop_swap<B1, Y, B2>(
        storage,
        coin_b1,
        coin_y,
        coin_out_min_value,
        ctx
      );

      coin::destroy_zero(coin_x);
      coin::destroy_zero(coin_b1);
      transfer::transfer(coin_y, sender);
      }
    }
  }

  entry public fun add_liquidity<X, Y>(
    storage: &mut Storage,
    vector_x: vector<Coin<X>>,
    vector_y: vector<Coin<Y>>,
    ctx: &mut TxContext
  ) {
    assert!(utils::are_coins_sorted<X, Y>(), ERROR_UNSORTED_COINS);

    let coin_x = coin::zero<X>(ctx);
    let coin_y = coin::zero<Y>(ctx);

    pay::join_vec(&mut coin_x, vector_x);
    pay::join_vec(&mut coin_y, vector_y);

    let coin_x_value = coin::value(&coin_x);
    let coin_y_value = coin::value(&coin_y);
    let sender = tx_context::sender(ctx);

    let (coin_x_reserves, coin_y_reserves, _) = dex::get_amounts(dex::borrow_pool<X, Y>(storage));

    let coin_x_optimal_value = (coin_y_value * coin_x_reserves) / coin_y_reserves;

    if (coin_x_value > coin_x_optimal_value) pay::split_and_transfer(&mut coin_x, coin_x_value - coin_x_optimal_value, sender, ctx);

    let coin_y_optimal_value = (coin_x_optimal_value * coin_y_reserves) / coin_x_reserves;

    if (coin_y_value > coin_y_optimal_value) pay::split_and_transfer(&mut coin_y, coin_y_value - coin_y_optimal_value, sender, ctx);


    transfer::transfer(
      dex::add_liquidity(
        storage,
        coin_x,
        coin_y,
        ctx
      ),
      tx_context::sender(ctx)
    )
  }

  entry public fun remove_liquidity<X, Y>(
    storage: &mut Storage,
    vector_lp_coin: vector<Coin<LPCoin<X, Y>>>,
    coin_amount_in: u64,
    ctx: &mut TxContext
  ){
    let coin = coin::zero<LPCoin<X, Y>>(ctx);
    
    pay::join_vec(&mut coin, vector_lp_coin);

    let coin_value = coin::value(&coin);

    let sender = tx_context::sender(ctx);

    if (coin_value > coin_amount_in) pay::split_and_transfer(&mut coin, coin_value - coin_amount_in, sender, ctx);

    let (coin_x, coin_y) = dex::remove_liquidity(
      storage,
      coin, 
      ctx
    );

    transfer::transfer(coin_x, sender);
    transfer::transfer(coin_y, sender);
  }

  fun safe_transfer<T>(
    coin: Coin<T>,
    ctx: &mut TxContext
    ) {
      if (coin::value(&coin) == 0) {
        coin::destroy_zero(coin);
      } else {
        transfer::transfer(coin, tx_context::sender(ctx));
      };
    }

  fun handle_swap_vectors<X, Y>(
    vector_x: vector<Coin<X>>,
    vector_y: vector<Coin<Y>>,
    coin_in_value: u64,
    ctx: &mut TxContext
  ): (Coin<X>, Coin<Y>) {
    let coin_x = coin::zero<X>(ctx);
    let coin_y = coin::zero<Y>(ctx);
    let sender = tx_context::sender(ctx);

    if (vector::is_empty(&vector_y)) {
      pay::join_vec(&mut coin_x, vector_x);
      vector::destroy_empty(vector_y);

      let coin_x_value = coin::value(&coin_x);
      if (coin_x_value > coin_in_value) pay::split_and_transfer(&mut coin_x, coin_x_value - coin_in_value, sender, ctx);
    } else {
      pay::join_vec(&mut coin_y, vector_y);
      vector::destroy_empty(vector_x);

      let coin_y_value = coin::value(&coin_y);
      if (coin_y_value > coin_in_value) pay::split_and_transfer(&mut coin_y, coin_y_value - coin_in_value, sender, ctx);
    };

    (coin_x, coin_y)
  }
}