use std::cmp::Ordering;
use std::field::bn254::decompose;
use std::ops::{Add, Div, Mul, Sub};

// IMPORTANT: This library is designed to work with a fixed scale factor of 2^16
// See further explanation in the `Quantized` struct comments below.
global scale: Field = 65536; // 2^16

// A signed fixed-point number `x` is represented in a single Field element.
//
// Representation Overview:
// A Field element is a type with 254 bits.
// We only use the first 126 or the last 126 bits.
// A positive number is within the first 126 bits.
// A negative numbers is within the last 126 bits.
// The "middle" 2 bits that are left over, should not be used.
// - Positive values have bits set in the lower part: |x_0,x_1,x_2,..,x_125, ... ,_,_,_,_|
// - Negative values have bits set in the upper part: |_,_,_,_, .. x_128,x_129,..,x_253|
// So following above visual, x_126 and x_127 MUST be 0
//
// Modular arithmetic ensures correct handling of signed fixed-point numbers by wrapping
// values around the field's modulus. For example, subtracting 5 from 3 in a field with
// modulus `p` results in (3 - 5) mod p = p - 2, representing -2. This behavior allows
// negative values to be correctly encoded in the field's upper range.
//
// Scaling:
// Since fields do not inherently support decimal values, the fixed-point representation
// uses a scale of 2^-16. This means that:
// - `Quantized { x: 1 }` represents the value 1/2^16.
// - To represent an original value, divide it by the scale, truncate, and store the result.
// Example:
// - Original value: 0.001
// - Scaled value: 0.001 * 2^16 = 65.536
// - Truncated result: 65 (stored as `Quantized { x: 65 }`)
//
// Overflow and overflow prevention:
// To make sure the arithmetic performed on a value will not overflow, the library contains
// bitsize checks that prevent numbers from growing larger than 126 bits. More concretely:
// - multiplication: inputs must have bitsize <= 63
// - addition: inputs must have bitsize <=125
// - subtraction: inputs must have bitsize <=125
//
// Conversion Steps to `Quantized`:
// 1. Check if the original value `x` is negative. If negative, use (p - |x|), where `p` is
//    the field's prime modulus. Otherwise, proceed with `x`.
// 2. Multiply the value by the scale factor (e.g., 2^16).
// 3. Store the scaled value in a `Quantized` struct.
//
// Prime Modulus:
// The field modulus `p` used in this implementation is:
//   p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
// This prime comes from the Barretenberg backend.
pub struct Quantized {
    pub x: Field,
}

// returns 1 for a negative element, 0 for a positive element
// A Quantized element is negative if the upper bits are set, so this is what we check for.
// NOTE: Make sure that the value that the field contains has maximum 126 bits.
// If the element contains more than 126 bits either way, this function cannot correctly indicate
// whether it's negative or not.
fn is_negative(x: Field) -> Field {
    let (_, higher_bytes) = decompose(x);
    if higher_bytes == 0 {
        0
    } else {
        1
    }
}

impl Quantized {
    // Assert that number of bits <= bitsize
    // if quantized is negative, it counts the bits backwards
    // NOTE: this works only for bitsize <= 126, because decompose gives us
    // 128 and 126 bits
    pub fn assert_bitsize<let bitsize: u32>(self: Self) {
        // Decomposes into two 128 bits chunks
        let (_, higher_bytes) = decompose(self.x);
        if higher_bytes == 0 {
            // positive number
            self.x.assert_max_bit_size::<bitsize>();
        } else {
            // negative number
            (-self.x).assert_max_bit_size::<bitsize>();
        }
    }

    pub fn zero() -> Self {
        Quantized { x: 0 }
    }

    pub fn new(x: Field) -> Self {
        let res = Self { x: x };
        res.assert_bitsize::<126>();
        res
    }

    fn add(self: Self, other: Self) -> Self {
        // To prevent overflow, allow max 125 bits for both inputs
        self.assert_bitsize::<125>();
        other.assert_bitsize::<125>();
        Quantized { x: self.x + other.x } // if one is negative, this wraps around automatically
    }

    fn sub(self: Self, other: Self) -> Self {
        // To prevent overflow, allow max 125 bits for both inputs
        self.assert_bitsize::<125>();
        other.assert_bitsize::<125>();
        Quantized { x: self.x - other.x }
    }

    fn mul(self: Self, other: Self) -> Self {
        // To prevent overflow, allow max 63 bits for both inputs
        // Perform multiplication of the underlying field elements
        // This doubles the scale.
        self.assert_bitsize::<63>();
        other.assert_bitsize::<63>();
        let mut temp: Field = self.x * other.x;

        // Scaling down by converting to byte array and chopping off the needed amount of bytes
        // Since the scale is a multiple of 2^8, this will scale it down correctly.
        // Note that we have to take care of the case that the value is negative; in that case we flip the sign
        // temporarily, and flip it back at the end. Otherwise the chopping won't work.

        // Check whether we're working with a negative value
        let negative = is_negative(temp);

        temp = negative
            * (
                21888242871839275222246405745257275088548364400416034343698204186575808495616 - temp
                    + 1
                    - temp
            )
            + temp;

        // Division by 2^16, code as suggested by Tom French @TomAFrench
        // Cast x to a u16 to preserve only the lowest 16 bits.
        let lowest_16_bits = temp as u16;

        // Subtract off the lowest 16 bits so they are cleared.
        let temp_with_cleared_lower_bits = temp - lowest_16_bits as Field;

        // The lowest 16 bits are clear, `x_with_cleared_lower_bits` is divisible by `65536`,
        // therefore field division is equivalent to integer division.
        let mut final_res: Field = temp_with_cleared_lower_bits / 65536;

        // If the result was originally negative, flip the sign back
        final_res = negative
            * (
                21888242871839275222246405745257275088548364400416034343698204186575808495616
                    - final_res
                    + 1
                    - final_res
            )
            + final_res;

        // Return the result as a new Quantized instance
        Quantized { x: final_res }
    }

    fn div(self: Self, other: Self) -> Self {
        // Ensure `other` is not zero
        assert(other.x != 0, "Division by zero is not allowed.");
        self.assert_bitsize::<109>(); // will be multiplied by scale later, so we allow 126-17 bits
        other.assert_bitsize::<126>(); // standard bitsize check
        // Flip signs of numerator and denominator if negative, work with their absolute values
        let mut numerator = self.x;
        let mut denominator = other.x;

        let mut numerator_is_negative = is_negative(numerator);
        let mut denominator_is_negative = is_negative(denominator);

        numerator = numerator_is_negative
            * (
                21888242871839275222246405745257275088548364400416034343698204186575808495616
                    - numerator
                    + 1
                    - numerator
            )
            + numerator;

        denominator = denominator_is_negative
            * (
                21888242871839275222246405745257275088548364400416034343698204186575808495616
                    - denominator
                    + 1
                    - denominator
            )
            + denominator;

        // Scale numerator before division
        let scaled_numerator = numerator * scale;

        // Cast to U128 for division
        let scaled_numerator_u128 = U128::from_le_bytes(scaled_numerator.to_le_bytes());
        let denominator_u128 = U128::from_le_bytes(denominator.to_le_bytes());

        // Perform the division in U128
        let result_u128 = scaled_numerator_u128 / denominator_u128;

        // Cast back to Field
        let mut result = Field::from_le_bytes(result_u128.to_le_bytes());

        // Determine the sign of the result
        let result_is_negative = numerator_is_negative + denominator_is_negative == 1;

        // If result is negative, flip sign back
        if result_is_negative {
            result = 21888242871839275222246405745257275088548364400416034343698204186575808495616
                - result
                + 1;
        }

        Quantized { x: result }
    }
}

impl Add for Quantized {
    fn add(self, other: Self) -> Self {
        self.add(other)
    }
}

impl Sub for Quantized {
    fn sub(self, other: Self) -> Self {
        self.sub(other)
    }
}

impl Mul for Quantized {
    fn mul(self, other: Self) -> Self {
        self.mul(other)
    }
}

impl Div for Quantized {
    fn div(self, other: Self) -> Self {
        self.div(other)
    }
}

impl Ord for Quantized {
    fn cmp(self: Self, other: Self) -> Ordering {
        if self.x == other.x {
            Ordering::equal()
        }

        let (_, sub_hi) = decompose(self.x - other.x);
        if (sub_hi == 0) {
            Ordering::greater()
        } else {
            Ordering::less()
        }
    }
}

#[test]
fn test_order() {
    // Test 1: comparison between positive and negative value.
    // a = 0.2 and b = -0.2
    let a: Field = 13107;
    let a_quantized = Quantized { x: a };
    let b = 21888242871839275222246405745257275088548364400416034343698204186575808482510;
    let b_quantized = Quantized { x: b };
    assert(a_quantized > b_quantized);

    // Test 2: comparison between two possitive numbers.
    // a = 1 and b = 0.2.
    // Then a * 2^16 = 65536
    let a: Field = 65536;
    let a_quantized = Quantized { x: a };
    let b = 13107;
    let b_quantized = Quantized { x: b };
    assert(a_quantized > b_quantized);

    // Test 3: comparison between two possitive numbers where the roles are
    // inverted.
    // a = 1 and b = 1.2.
    // Then a * 2^16 = 65536
    let a: Field = 65536;
    let a_quantized = Quantized { x: a };
    let b = 78643;
    let b_quantized = Quantized { x: b };
    assert(a_quantized < b_quantized);

    // Test 4: comparison between two negative numbers.
    // a = -1 and b = -0.2.
    // Then a * 2^16 = -65536 therefore taking mod p we obtain that
    // a = 21888242871839275222246405745257275088548364400416034343698204186575808430081
    // b = 21888242871839275222246405745257275088548364400416034343698204186575808482510
    let a: Field = 21888242871839275222246405745257275088548364400416034343698204186575808430081;
    let a_quantized = Quantized { x: a };
    let b = 21888242871839275222246405745257275088548364400416034343698204186575808482510;
    let b_quantized = Quantized { x: b };
    assert(a_quantized < b_quantized);

    // 21888242871839275222246405745257275088548364400416034343698204186575808495617 - 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efff8001
    // - 32768
    // 21888242871839275222246405745257275088548364400416034343698204186575808495617 - 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effb0001
    let a = Quantized { x: 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efff8001 };
    // - 327680
    let b = Quantized { x: 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593effb0001 };
    assert(a > b);
}

#[test]
fn test_is_negative() {
    // Test 1: checking if it's negative for a positive value.
    // a = 0.2   =>   0.2 * 2^16 = 13107
    let a: Field = 13107;
    assert(is_negative(a) == 0);

    // Test 2: checking if it's negative for a negative value.
    // a = -0.2  =>   -0.2 * 2^16 = -13107
    // Hence, -13107 mod p = p - 13107 = 21888242871839275222246405745257275088548364400416034343698204186575808482510
    let a = 21888242871839275222246405745257275088548364400416034343698204186575808482510;
    assert(is_negative(a) == 1);

    // Test 3: checing if it's negative for a negative larger value.
    // a = -1301.34  =>  -1301.34 * 2^16 = -85284618
    // Hence, -85284618 mod p = p - 85284618 = 21888242871839275222246405745257275088548364400416034343698204186575723210999
    let a = 21888242871839275222246405745257275088548364400416034343698204186575723210999;
    assert(is_negative(a) == 1);
}

#[test]
fn test_add() {
    // Max value 2^60-1, positive and negative
    let a = 1152921504606846975;
    let b = -1152921504606846975;
    let a_quantized = Quantized { x: a };
    let b_quantized = Quantized { x: b };
    let addition_quantized = a_quantized + b_quantized;
    assert(addition_quantized.x == 0);

    // Test case 1: Max value 2^60 - 1, positive and zero
    let a1 = 1152921504606846975;
    let b1 = 0;
    let a1_quantized = Quantized { x: a1 };
    let b1_quantized = Quantized { x: b1 };
    let addition1_quantized = a1_quantized + b1_quantized;
    assert(addition1_quantized.x == a1);

    // Test case 2: Small positive values
    let a2 = 12345;
    let b2 = 67890;
    let a2_quantized = Quantized { x: a2 };
    let b2_quantized = Quantized { x: b2 };
    let addition2_quantized = a2_quantized + b2_quantized;
    assert(addition2_quantized.x == (a2 + b2));

    // Test case 3: Positive and negative values resulting in a non-zero positive result
    let a3 = 50000;
    let b3 = -30000;
    let a3_quantized = Quantized { x: a3 };
    let b3_quantized = Quantized { x: b3 };
    let addition3_quantized = a3_quantized + b3_quantized;
    assert(addition3_quantized.x == 20000);

    // Test case 4: Positive and negative values resulting in a non-zero negative result
    let a4 = 30000;
    let b4 = -50000;
    let a4_quantized = Quantized { x: a4 };
    let b4_quantized = Quantized { x: b4 };
    let addition4_quantized = a4_quantized + b4_quantized;
    assert(addition4_quantized.x == -20000);

    // Test case 5: Add two negative values resulting in a negative value
    let a5 = -40000;
    let b5 = -20000;
    let a5_quantized = Quantized { x: a5 };
    let b5_quantized = Quantized { x: b5 };
    let addition5_quantized = a5_quantized + b5_quantized;
    assert(addition5_quantized.x == -60000);
}

#[test]
fn test_mul() {
    // Test case 1: Small positive values
    let a1 = 12345; // original value 12345/2^16 = 0.1883697509765625
    let b1 = 67890; // original value 67890/2^16 = 1.035919189453125
    let a1_quantized = Quantized { x: a1 };
    let b1_quantized = Quantized { x: b1 };
    // new value = 0.1883697509765625 * 1.035919189453125 = 0.1951358397491276264190673828125
    // x = 0.1951358397491276264190673828125 * 2^16 = 12788.422393798828125 => 12788
    let mult1_quantized = a1_quantized * b1_quantized;
    assert(mult1_quantized.x == 12788);

    // Test case 2: Large positive values
    let a2 = 1152921504606846975; // Max value 2^60 - 1, original 1152921504606846975/2^16 = 17592186044415.9999847412109375
    let b2 = 2; // original 2/2^16 = 0.000030517578125
    let a2_quantized = Quantized { x: a2 };
    let b2_quantized = Quantized { x: b2 };
    let mult2_quantized = a2_quantized * b2_quantized;
    // 17592186044415.9999847412109375 * 0.000030517578125 = 536870911.9999999995343387126922607421875
    // x/2^16 = value;  mult by 2^16 and truncate to whole number => x = 35184372088831
    assert(mult2_quantized.x == 35184372088831);

    // Test case 3: Large positive and small positive value
    let a3 = 1152921504606846975; // Max value 2^60 - 1, original 1152921504606846975/2^16 = 17592186044415.9999847412109375
    let b3 = 1; // original value 1/2^16 = 0.0000152587890625
    let a3_quantized = Quantized { x: a3 };
    let b3_quantized = Quantized { x: b3 };
    // mul = 17592186044415.9999847412109375 * 0.0000152587890625 = 268435455.99999999976716935634613037109375
    let mult3_quantized = a3_quantized * b3_quantized;
    // mul * 2^16 = 17592186044415.9999847412109375
    assert(mult3_quantized.x == 17592186044415);

    // Test case 4: Positive and negative value
    let a4 = 40000; // Original value 40000/2^16 = 0.6103515625
    let b4 = -30000; // Original value -0.457763671875
    let a4_quantized = Quantized { x: a4 };
    let b4_quantized = Quantized { x: b4 };

    // 0.6103515625 * -0.457763671875 = -0.2793967723846435546875
    let mult4_quantized = a4_quantized * b4_quantized;
    // -0.2793967723846435546875 * 2^16 = -18310.546875
    assert(mult4_quantized.x == -18310);

    // Test case 5: Both values negative
    let a5 = -40000; // Original value -40000 / 2^16 = -0.6103515625
    let b5 = -20000; // -0.30517578125
    let a5_quantized = Quantized { x: a5 };
    let b5_quantized = Quantized { x: b5 };
    // -0.6103515625 *  -0.30517578125 = 0.186264514923095703125
    let mult5_quantized = a5_quantized * b5_quantized;
    // Expected result: 12207.03125
    assert(mult5_quantized.x == 12207);
}

#[test]
fn test_sub() {
    let a = 1152921504606846975;
    let b = 1152921504606846975;
    let a_quantized = Quantized { x: a };
    let b_quantized = Quantized { x: b };
    let addition_quantized = a_quantized - b_quantized;
    assert(addition_quantized.x == 0);

    let a1 = 1152921504606846975;
    let b1 = 0;
    let a1_quantized = Quantized { x: a1 };
    let b1_quantized = Quantized { x: b1 };
    let addition1_quantized = a1_quantized - b1_quantized;
    assert(addition1_quantized.x == a1);

    let a1 = 1152921504606846975;
    let b1 = 0;
    let a1_quantized = Quantized { x: a1 };
    let b1_quantized = Quantized { x: b1 };
    let addition1_quantized = b1_quantized - a1_quantized;
    // The result should be -a1, which means it is p - a1 in the field because
    // of the wrap around.
    let result = 21888242871839275222246405745257275088548364400416034343697051265071201648642;
    assert(addition1_quantized.x == result);

    let a2 = 12345;
    let b2 = 67890;
    let a2_quantized = Quantized { x: a2 };
    let b2_quantized = Quantized { x: b2 };
    let addition2_quantized = a2_quantized + b2_quantized;
    assert(addition2_quantized.x == (a2 + b2));
}

#[test]
fn test_division() {
    // Field modulus
    let p: Field = 0;

    // Test case 1: Division with small positive values
    let a1 = Quantized { x: 98304 }; // Represents 1.5 (scaled)
    let b1 = Quantized { x: 65536 }; // Represents 1.0 (scaled)
    let result1 = a1 / b1; // 1.5 / 1.0 = 1.5
    assert(result1.x == 98304); // Scaled result for 1.5

    // Test case 2: Division resulting in a smaller value
    let a2 = Quantized { x: 65536 }; // Represents 1.0 (scaled)
    let b2 = Quantized { x: 98304 }; // Represents 1.5 (scaled)
    let result2 = a2 / b2; // 1.0 / 1.5 = 0.666...
    assert(result2.x == 43690); // Scaled result for ~0.6667

    // Test case 3: Negative divided by positive
    let a3 = Quantized { x: p - 98304 }; // Represents -1.5 (scaled)
    let b3 = Quantized { x: 65536 }; // Represents 1.0 (scaled)
    let result3 = a3 / b3; // -1.5 / 1.0 = -1.5
    assert(result3.x == p - 98304); // Correctly negative

    // Test case 4: Positive divided by negative
    let a4 = Quantized { x: 98304 }; // Represents 1.5 (scaled)
    let b4 = Quantized { x: p - 65536 }; // Represents -1.0 (scaled)
    let result4 = a4 / b4; // 1.5 / -1.0 = -1.5
    assert(result4.x == p - 98304); // Correctly negative

    // Test case 5: Both negative values
    let a5 = Quantized { x: p - 98304 }; // Represents -1.5 (scaled)
    let b5 = Quantized { x: p - 65536 }; // Represents -1.0 (scaled)
    let result5 = a5 / b5; // -1.5 / -1.0 = 1.5
    assert(result5.x == 98304); // Scaled result for 1.5
}

#[test]
fn test_large_values_division() {
    // Field modulus
    let p: Field = 0;

    // Test case 1: Large positive values
    let a1 = Quantized { x: 1152921504606846976 }; // Represents 17592186044416.0 (scaled)
    let b1 = Quantized { x: 576460752303423488 }; // Represents 8796093022208.0 (scaled)
    let result1 = a1 / b1; // 17592186044416.0 / 8796093022208.0 = 2.0
    assert(result1.x == 131072); // Scaled result for 2.0

    // Test case 2: Large positive divided by a larger positive
    let a2 = Quantized { x: 576460752303423488 }; // Represents 8796093022208.0 (scaled)
    let b2 = Quantized { x: 1152921504606846976 }; // Represents 17592186044416.0 (scaled)
    let result2 = a2 / b2; // 8796093022208.0 / 17592186044416.0 = 0.5
    assert(result2.x == 32768); // Scaled result for 0.5

    // Test case 3: Large negative divided by large positive
    let a3 = Quantized { x: p - 1152921504606846976 }; // Represents -17592186044416.0 (scaled)
    let b3 = Quantized { x: 576460752303423488 }; // Represents 8796093022208.0 (scaled)
    let result3 = a3 / b3; // -17592186044416.0 / 8796093022208.0 = -2.0
    assert(result3.x == p - 131072); // Correctly negative

    // Test case 4: Large positive divided by large negative
    let a4 = Quantized { x: 1152921504606846976 }; // Represents 17592186044416.0 (scaled)
    let b4 = Quantized { x: p - 576460752303423488 }; // Represents -8796093022208.0 (scaled)
    let result4 = a4 / b4; // 17592186044416.0 / -8796093022208.0 = -2.0
    assert(result4.x == p - 131072); // Correctly negative

    // Test case 5: Both large negative values
    let a5 = Quantized { x: p - 1152921504606846976 }; // Represents -17592186044416.0 (scaled)
    let b5 = Quantized { x: p - 576460752303423488 }; // Represents -8796093022208.0 (scaled)
    let result5 = a5 / b5; // -17592186044416.0 / -8796093022208.0 = 2.0
    assert(result5.x == 131072); // Scaled result for 2.0
}

#[test(should_fail)]
fn test_division_by_zero() -> Quantized {
    Quantized { x: 65536 } / Quantized { x: 0 }
}
