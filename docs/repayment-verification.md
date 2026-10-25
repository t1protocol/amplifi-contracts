# Repayment verification

Run the multi-block scenario with its step-by-step repayment log:

```sh
forge test --match-contract RepaymentSequenceTest -vv
```

It uses two depositors and three loans opened at different times, advances both
block number and timestamp four times, and exercises interest-only, partial and
full payments, refunds, fee collection and lender exits. A separate dollar-based
10% annual-rate model checks each loan's debt/principal and aggregate accounting
after operations. It does not use the pool's index/share conversion helpers.
Final token conservation is exact; intermediate comparisons allow micro-unit
rounding differences. This deterministic scenario is not a stateful invariant
fuzzer or a test of different utilization-dependent rates.

Run the execution forks:

```sh
POLYGON_RPC_URL=https://polygon-bor-rpc.publicnode.com \
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --match-path test/RepaymentExecutionFork.t.sol -vv
```

Defaults are pinned to Polygon block 96,163,226 and Robinhood block 97,767,524.
Override with `POLYGON_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK`. Missing RPC variables
produce explicit skips; configured RPC failures fail the tests.

## Polygon deposit wallet

The tests deploy a wallet through the real factory at
`0x00000000000Fb5C9ADea0298D729A0CB3823Cc07`, using its deployed beacon implementation,
and deploy the proposed pool only on the fork. They sign the SDK-compatible
EIP-712 Batch/Call payload using a dummy test owner key and submit through the
factory's `proxy` entrypoint. The real pUSD contract moves the funds.

Only the fork's test relayer receives a factory operator role, granted by
impersonating the factory owner locally. Wallet signatures, nonce checks and
call execution are not mocked or bypassed. Tests cover partial/full repayment
across blocks, excess refunds, missing checkpoints, incorrect amounts, wrong
signatures, replay protection and atomic rollback of transfers and wallet nonces.

These tests do not contact the relayer HTTP service. They cannot establish its
target/call admission policy, queue behavior or submission/retry handling. A real
three-call relayer staging submission remains required.

Factory and wallet interfaces were checked against their verified Polygon code:

- [Factory](https://polygonscan.com/address/0x00000000000Fb5C9ADea0298D729A0CB3823Cc07#code)
- [Beacon implementation at the pinned block](https://polygonscan.com/address/0xf7f27C29e60fe6325beF8dA7F93250353d2e3294#code)

## Robinhood treasury allowance

Fixtures check the existing pool's asset and operator against the real USDG
token and treasury. The treasury's live EIP-7702 Simple7702Account delegation is
preserved. Tests exercise ordinary treasury calls and its actual delegated
`executeBatch`, including approval, partial/full payment, accrued interest,
refunds, unauthorized callers, missing approval and signed loss settlement.
Token balances are seeded with Foundry `deal`; no real funds or keys are used.

Passing these tests establishes that the allowance API works with that token
and treasury execution code. It does not establish Juiced application integration.
The Juiced source's `contracts/src/JuicedAccount.sol::_repayPool` currently pushes
tokens and calls the old `repay` without `beginRepay`; that path requires explicit
v2 adaptation and end-to-end coverage before migration. The treasury allowance
API alone does not make those user-account contracts compatible.

Neither fork sends transactions to a live network. They test new pool deployments,
not upgrades to existing deployed pools.
