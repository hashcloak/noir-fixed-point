# Fixed-Point Arithmetic Library

This is an optimized fixed point arithmetic library designed for scale 2^-16. It supports signed fixed-point numbers with a specific scale of 2^-16 and provides efficient implementations of standard arithmetic operations such as addition, subtraction, and multiplication.

## Usage


To create a fixed-point number, divide the original value by 2^16 and store the resulting integer:
```rust
let value = Quantized::new(65536); // Represents 65536 / 2^16 = 1.0
let small_value = Quantized::new(32768); // Represents 32768 / 2^16 = 0.5
let large_value = Quantized::new(131072); // Represents 131072 / 2^16 = 2.0
```

Arithmetic operations. Note that for multiplication we always scale down the value so the result has the same scale as before. 

```rust
let a = Quantized::new(98304); // Represents 1.5
let b = Quantized::new(147456); // Represents 2.25

let add = a + b; // (98304 + 147456) / 2^16 = 3.75
let sub = a - b; // (98304 - 147456) / 2^16 = -0.75
let mul = a * b; // (98304 * 147456) / 2^(16 + 16) = 3.375
```

### Check Negativity
You can check whether a fixed-point value is negative:
```rust
let negative_value = Quantized::new(-32768); // Represents -0.5
let is_negative = is_negative(negative_value.x); // Returns 1 (true)

let positive_value = Quantized::new(65536); // Represents 1.0
let is_positive_negative = is_negative(positive_value.x); // Returns 0 (false)
```

## Testing

Run tests with:
```bash
cargo test
```

## Benchmarks

Gatecounts: 
Addition & subtraction: 4217.
Multiplication: 2932
Division: 3732.
Ordering: 2789. 

Rerun benchmarks in folder `benchmarks`.

- Nargo `1.0.0-beta.0`
- bb `0.63.0`