module ipx::utils {
  use std::type_name::{Self};
  use std::string::{Self, String}; 
  use std::ascii;

  use ipx::comparator;

    const EQUAL: u8 = 0;
    const SMALLER: u8 = 1;
    const GREATER: u8 = 2;

    const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 0;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 2;
    const ERROR_INSUFFICIENT_OUTPOT_AMOUNT: u64 = 3;
    const ERROR_SAME_COIN: u64 = 4;

    public fun get_smaller_enum(): u8 {
        SMALLER
    }

    public fun get_greater_enum(): u8 {
        GREATER
    }

    public fun get_equal_enum(): u8 {
        EQUAL
    }

    public fun get_coin_info<T>(): vector<u8> {
       let name = type_name::into_string(type_name::get<T>());
       ascii::into_bytes(name)
    }

    fun compare_struct<X,Y>(): u8 {
        let struct_x_bytes: vector<u8> = get_coin_info<X>();
        let struct_y_bytes: vector<u8> = get_coin_info<Y>();
        if (comparator::is_greater_than(&comparator::compare_u8_vector(struct_x_bytes, struct_y_bytes))) {
            GREATER
        } else if (comparator::is_equal(&comparator::compare_u8_vector(struct_x_bytes, struct_y_bytes))) {
            EQUAL
        } else {
            SMALLER
        }
    }

    public fun are_coins_sorted<X,Y>(): bool {
        let compare_x_y: u8 = compare_struct<X, Y>();
        assert!(compare_x_y != get_equal_enum(), ERROR_SAME_COIN);
        (compare_x_y == get_smaller_enum())
    }

    public fun get_lp_coin_name<X, Y>(): String {
      let lp_name = string::utf8(b"");

      string::append_utf8(&mut lp_name, ascii::into_bytes(type_name::into_string(type_name::get<X>())));
      string::append_utf8(&mut lp_name, b"-");
      string::append_utf8(&mut lp_name, ascii::into_bytes(type_name::into_string(type_name::get<Y>())));
      
      lp_name
    }
}