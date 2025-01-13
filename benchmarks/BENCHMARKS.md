# Benchmarks fixed point arithmetic lib

## Run benchmarks

Uncomment the `main` function in `project/src/main.nr` that should be benchmarked and run:
```=bash
$ nargo compile
$ bb gates -b target/project.json
```

## Output (Jan 2025)

- Nargo `1.0.0-beta.0`
- bb `0.63.0`

Gatecounts: 
Addition & subtraction: 17.
Multiplication: 3229
Division: 3289.
Ordering: 2789. 