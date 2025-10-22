# Uniswap V4 Learn

Learning Uniswap's V4 Router.

## Test

### ENV

In order to run a successful test you must add an `.env` file with a `FORK_URL` variable with a value of an RPC URL from your RPC provider.

### Run Test

Run the test with the following command:

```bash
forge test --fork-url $FORK_URL -vvv
```

Passing tests should print a similar output to console as the below:

```bash
[⠊] Compiling...
No files changed, compilation skipped

Ran 1 test for test/Flash.t.sol:FlashTest
[PASS] test_flash() (gas: 83969)
Logs:
  Borrowed amount: 1e9 USDC

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.33s (636.08ms CPU time)

Ran 1 test suite in 1.73s (1.33s CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```

# Resources

This is test example from Cyfrin Updraft's [Uniswap V4 course](https://github.com/Cyfrin/defi-uniswap-v4).