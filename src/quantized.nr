use std::cmp::Ordering;
use std::field::bn254::decompose;
use std::ops::{Add, Div, Mul, Sub};

// IMPORTANT: This library is designed to work with a scale factor of 2^(8*factor).
// See further explanation in the `Quantized` struct comments below.
global factor: u32 = 2;
global scale: Field = 65536; // 2^(8*2) = 2^16

/////////// Other options:
// global factor = 1
// global scale = 256; // 2^(8*1) = 2^8

// global factor = 3
// global scale = 16777216; // 2^(8*3) = 2^24
/////////// END Other options

// A signed fixed-point number `x` is represented in a single Field element.
//
// Representation Overview:
// A finite Field has 254 bits of "space". We represent positive fixed-point numbers
// in the first half of these bits and negative fixed-point numbers in the second half.
// Here's a visualization of the field element:
// - Positive values have bits set in the lower part: |x,x,x,x,..,x, ... ,_,_,_,_|
// - Negative values have bits set in the upper part: |_,_,_,_, .. x,x,x,..,x|
//
// Modular arithmetic ensures correct handling of signed fixed-point numbers by wrapping
// values around the field's modulus. For example, subtracting 5 from 3 in a field with
// modulus `p` results in (3 - 5) mod p = p - 2, representing -2. This behavior allows
// negative values to be correctly encoded in the field's upper range.
//
// Scaling:
// Since fields do not inherently support decimal values, the fixed-point representation
// uses scaling. For example, a scale of 2^-16 means that:
// - `Quantized { x: 1 }` represents the value 1/2^16.
// - To represent an original value, divide it by the scale, truncate, and store the result.
// Example:
// - Original x: 0.001
// - Scaled x: 0.001 * 2^16 = 65.536
// - Truncated result: 65 (stored as `Quantized { x: 65 }`)
//
// Range and Precision:
// A `Quantized` value can have a maximum of 60 bits, leaving room for additional operations
// like multiplications and additions. This limits the stored value to the range:
//   [-2^60 + 1, 2^60 - 1] (approximately -1.15e18 to 1.15e18).
// The unscaled range is therefore:
//   [-2^60/scale, 2^60/scale].
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
    pub is_negative: bool,
}

impl Quantized {
    pub fn zero() -> Self {
        Quantized { x: 0, is_negative: false }
    }

    pub fn new(x: Field, is_negative: bool) -> Self {
        Self { x, is_negative }
    }

    fn add(self: Self, other: Self) -> Self {
        let mut result = Quantized::zero();
        if self.is_negative & other.is_negative {
            result = Self { x: self.x - other.x, is_negative: true };
        } else if self.is_negative {
            if self.x.lt(other.x) {
                result = Quantized { x: other.x - self.x, is_negative: false };
            } else {
                result = Quantized { x: self.x - other.x, is_negative: true };
            }
        } else if other.is_negative {
            if other.x.lt(self.x) {
                result = Quantized { x: self.x - other.x, is_negative: false };
            } else {
                result = Quantized { x: other.x - self.x, is_negative: true };
            }
        } else {
            result = Quantized { x: other.x + self.x, is_negative: false }; // not doing this at the beginning in case there is overflow
        }
        result
    }

    fn sub(self: Self, other: Self) -> Self {
        let neg_other = Quantized { x: other.x, is_negative: !other.is_negative };
        self.add(neg_other)
    }

    fn mul(self: Self, other: Self) -> Self {
        let mult_result = (self.x * other.x); // U128 multiplication, will overflow if needed. Divide by 2^16 to adjust scaling
        let sign = self.is_negative ^ other.is_negative; // XOR to determine sign

        Quantized { x: mult_result, is_negative: sign }
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

impl Ord for Quantized {
    fn cmp(self: Self, other: Self) -> Ordering {
        if self.is_negative != other.is_negative {
            if self.is_negative {
                Ordering::less()
            } else {
                Ordering::greater()
            }
        }

        if self.is_negative {
            // Both are negative numbers.
            if self.x.lt(other.x) {
                Ordering::greater()
            } else {
                Ordering::less()
            }
        } else {
            // Both are possitive numbers.
            if self.x.lt(other.x) {
                Ordering::less()
            } else {
                Ordering::greater()
            }
        }
    }
}

/* #[test]
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
 */

