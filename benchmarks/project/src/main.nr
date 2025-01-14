use dep::quantized::quantized::Quantized;
use std::cmp::Ordering;

// addition, sub  17
// mul 3229
// div 3285
// fn main(x: Quantized, y: Quantized) -> pub Quantized {
//     // x + y
//     // x - y
//     // x * y
//     x / y
// }

// ordering 2789
fn main(x: Quantized, y: Quantized) -> pub Ordering {
    x.cmp(y)
}

