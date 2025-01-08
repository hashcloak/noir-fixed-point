use std::cmp::Ordering;
use std::field::bn254::decompose;
use std::ops::{Add, Mul, Sub};

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
// - Original value: 0.001
// - Scaled value: 0.001 * 2^16 = 65.536
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
}

pub unconstrained fn get_bytes(x: Field) -> [u8; 32] {
    x.to_be_bytes()
}

// returns 1 for true, 0 for false (checking for this is cheaper than working with a bool)
// A Quantized element is negative if the upper bits are set, so this is what we check for.
// Make sure that the value that the field contains has maximum ~127 bits
// (otherwise a positive value will "overflow" into the higher bits, as well as a negative
// value would overflow into lower bits)
fn is_negative(x: Field) -> Field {
    let (_, higher_bytes) = decompose(x);
    if higher_bytes == 0 {
        0
    } else {
        1
    }
}

impl Quantized {

    pub fn zero() -> Self {
        Quantized { x: 0 }
    }

    pub fn new(x: Field) -> Self {
        Self { x: x }
    }

    fn add(self: Self, other: Self) -> Self {
        Quantized { x: self.x + other.x } // if one is negative, this wraps around automatically
    }

    fn sub(self: Self, other: Self) -> Self {
        Quantized { x: self.x - other.x }
    }

    fn mul(self: Self, other: Self) -> Self {
        // Perform multiplication of the underlying field elements
        // This doubles the scale.
        let mut temp: Field = self.x * other.x;

        // Scaling down by converting to byte array and chopping off the needed amount of bytes
        // Since the scale is a multiple of 2^8, this will scale it down correctly.
        // Note that we have to take care of the case that the value is negative; in that case we flip the sign
        // temporarily, and flip it back at the end. Otherwise the chopping won't work.

        let mut bytes: [u8; 32] = [0; 32];
        // Check whether we're working with a negative value
        let negative = is_negative(temp);

        // If the result is negative, flip its sign to work with the positive equivalent
        if negative == 1 {
            temp = 21888242871839275222246405745257275088548364400416034343698204186575808495616
                - temp
                + 1;
            unsafe {
                bytes = get_bytes(temp);
            }

            // Ensure the new bytes representation matches the modified field element
            assert(Field::from_be_bytes::<32>(bytes) == temp);
        } else {
            unsafe {
                bytes = get_bytes(temp);
            }

            // Verify that the bytes representation matches the original field element
            assert(Field::from_be_bytes::<32>(bytes) == temp);
        }

        // Truncate the bytes to scale down by 2^(8 * factor)
        // This effectively "chops off" the least significant <factor> bytes
        let mut truncated: [u8; 32] = [0; 32];
        for i in 0..30 {
            truncated[i + factor] = bytes[i];
        }

        // Reconstruct the field element from the truncated bytes
        let mut new_x: Field = Field::from_be_bytes::<32>(truncated);

        // If the result was originally negative, flip the sign back
        if negative == 1 {
            new_x = 21888242871839275222246405745257275088548364400416034343698204186575808495616
                - new_x
                + 1;
        }

        // Return the result as a new Quantized instance
        Quantized { x: new_x }
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
